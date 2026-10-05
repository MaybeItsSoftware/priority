import Foundation
import OSLog
import TaktCore

/// Anything that can call a tool on an AFFiNE MCP server.
///
/// The export service talks to this rather than to a process, so its rules —
/// which tool, in what order, with what arguments — can be tested without node
/// on the machine.
protocol AFFiNEToolCalling: Sendable {
  func callTool(_ name: String, arguments: [String: JSONValue]) async throws -> JSONValue
}

enum AFFiNEMCPError: LocalizedError, Equatable {
  case helperNotFound(String)
  case launchFailed(String)
  case timedOut(tool: String, seconds: Int)
  case transport(String)
  case server(code: Int, message: String)
  case toolFailed(tool: String, message: String)
  case unexpectedResult(tool: String)
  case documentNotRewritable(title: String)

  var errorDescription: String? {
    switch self {
    case .helperNotFound(let message):
      return message
    case .launchFailed(let message):
      return "Could not start affine-mcp: \(message)"
    case .timedOut(let tool, let seconds):
      return "AFFiNE did not answer \(tool) within \(seconds)s."
    case .transport(let message):
      return "Lost the connection to affine-mcp: \(message)"
    case .server(let code, let message):
      return "AFFiNE server error \(code): \(message)"
    case .toolFailed(let tool, let message):
      return message.isEmpty ? "AFFiNE rejected \(tool)." : message
    case .unexpectedResult(let tool):
      return "AFFiNE returned something \(tool) could not be read from."
    case .documentNotRewritable(let title):
      return """
        \u{201C}\(title)\u{201D} holds blocks Takt cannot rewrite safely \
        (a database, an embed, or similar), so it was left untouched. Move \
        those blocks to another document, or point Takt at a different one.
        """
    }
  }
}

/// One `affine-mcp` process, spoken to over stdio.
///
/// A session is short-lived by design: it is started for a request and torn
/// down after it, because the alternative — a resident node process, its
/// AFFiNE session going stale in the background — is a lifecycle problem in
/// exchange for latency nobody is waiting on. Exports are a keypress, not a
/// loop.
///
/// `@unchecked Sendable`: every mutable field is touched only from `queue`,
/// which is serial, and the async surface funnels through `perform`.
final class AFFiNEMCPSession: AFFiNEToolCalling, @unchecked Sendable {

  struct Launch: Sendable {
    let executablePath: String
    /// PATH for the child. `affine-mcp` is a `#!/usr/bin/env node` script, so
    /// this has to contain a node — see `AFFiNEHelperLocator.searchPath`.
    let searchPath: String
    /// Merged over the inherited environment. Credentials are deliberately not
    /// in here: they stay in the user's own `~/.config/affine-mcp/config`,
    /// written by `affine-mcp login`, so Priority never handles an AFFiNE
    /// password.
    let extraEnvironment: [String: String]
  }

  private let logger = Logger(subsystem: "uk.co.maybeitssoftware.takt", category: "affine")
  private let launch: Launch
  private let timeout: TimeInterval
  private let queue = DispatchQueue(label: "uk.co.maybeitssoftware.takt.affine-mcp")

  /// Guards `process` alone, because the watchdog terminates it from off the
  /// serial queue — that being the whole point of a watchdog.
  private let processLock = NSLock()
  private var process: Process?
  private var standardInput: FileHandle?
  private var standardOutput: FileHandle?
  private var buffer = Data()
  private var nextRequestId = 1
  private let stderrLock = NSLock()
  private var stderrTail = Data()

  init(launch: Launch, timeout: TimeInterval = 45) {
    self.launch = launch
    self.timeout = timeout
  }

  deinit {
    runningProcess()?.terminate()
  }

  func callTool(_ name: String, arguments: [String: JSONValue]) async throws -> JSONValue {
    let result = try await perform(named: name) { session in
      try session.startIfNeeded()
      let id = session.takeRequestId()
      try session.send(MCPWire.toolCallRequest(id: id, name: name, arguments: arguments))
      return try session.readResult(id: id)
    }

    if MCPWire.toolResultIsError(result) {
      throw AFFiNEMCPError.toolFailed(tool: name, message: MCPWire.toolResultText(result))
    }
    return result
  }

  /// Ends the process. Safe to call on a session that never started.
  func close() {
    queue.async { [self] in
      standardInput?.closeFile()
      let running = runningProcess()
      running?.terminate()
      setProcess(nil)
      standardInput = nil
      standardOutput = nil
      buffer = Data()
    }
  }

  // MARK: - Serial execution

  private func perform<T: Sendable>(
    named tool: String,
    _ body: @escaping @Sendable (AFFiNEMCPSession) throws -> T
  ) async throws -> T {
    // The reads below block their thread, so the watchdog cannot interrupt them
    // directly. Terminating the process does: the pending read returns EOF and
    // unwinds as a transport error, which `timedOut` then replaces.
    let expired = ExpiryFlag()
    let watchdog = DispatchWorkItem { [weak self] in
      expired.mark()
      self?.runningProcess()?.terminate()
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
    defer { watchdog.cancel() }

    do {
      return try await withCheckedThrowingContinuation { continuation in
        queue.async { [self] in
          do {
            continuation.resume(returning: try body(self))
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    } catch {
      // A read that unwound because the watchdog killed the process reads as a
      // transport failure; report the cause rather than the symptom.
      if expired.isSet, case AFFiNEMCPError.transport = error {
        throw AFFiNEMCPError.timedOut(tool: tool, seconds: Int(timeout))
      }
      throw error
    }
  }

  // MARK: - Process (queue-confined)

  private func startIfNeeded() throws {
    if let running = runningProcess(), running.isRunning { return }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: launch.executablePath)
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = launch.searchPath
    for (key, value) in launch.extraEnvironment { environment[key] = value }
    process.environment = environment

    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors

    // Kept only to describe a failure: a server that cannot sign in says so on
    // stderr and then exits, which otherwise surfaces as a bare EOF.
    errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty, let self else { return }
      stderrLock.lock()
      stderrTail.append(chunk)
      if stderrTail.count > 4096 { stderrTail.removeFirst(stderrTail.count - 4096) }
      stderrLock.unlock()
    }

    do {
      try process.run()
    } catch {
      throw AFFiNEMCPError.launchFailed(error.localizedDescription)
    }

    setProcess(process)
    self.standardInput = input.fileHandleForWriting
    self.standardOutput = output.fileHandleForReading
    self.buffer = Data()

    let id = takeRequestId()
    try send(
      MCPWire.initializeRequest(
        id: id,
        clientName: "Takt",
        clientVersion: Bundle.main.shortVersionString
      ))
    _ = try readResult(id: id)
    try send(MCPWire.initializedNotification())
  }

  private func runningProcess() -> Process? {
    processLock.lock()
    defer { processLock.unlock() }
    return process
  }

  private func setProcess(_ newValue: Process?) {
    processLock.lock()
    process = newValue
    processLock.unlock()
  }

  private func takeRequestId() -> Int {
    defer { nextRequestId += 1 }
    return nextRequestId
  }

  private func send(_ message: JSONValue) throws {
    guard let standardInput else {
      throw AFFiNEMCPError.transport("the server is not running")
    }
    do {
      try standardInput.write(contentsOf: MCPWire.encode(message))
    } catch {
      throw AFFiNEMCPError.transport(error.localizedDescription)
    }
  }

  private func readResult(id: Int) throws -> JSONValue {
    guard let standardOutput else {
      throw AFFiNEMCPError.transport("the server is not running")
    }

    while true {
      if let line = takeLine() {
        switch MCPWire.decode(line: line) {
        case .result(let messageId, let value) where messageId == id:
          return value
        case .failure(let messageId, let code, let message) where messageId == id:
          throw AFFiNEMCPError.server(code: code, message: message)
        default:
          // A notification, a log line, or a reply to a request that has
          // already timed out. None of them is this call's answer.
          continue
        }
      }

      let chunk = standardOutput.availableData
      guard !chunk.isEmpty else {
        throw AFFiNEMCPError.transport(exitDiagnostic())
      }
      buffer.append(chunk)
    }
  }

  /// The next complete line in the buffer, consumed, or `nil` if one has not
  /// arrived yet.
  private func takeLine() -> String? {
    guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
    let lineData = buffer[buffer.startIndex..<newline]
    buffer.removeSubrange(buffer.startIndex...newline)
    return String(data: lineData, encoding: .utf8)
  }

  private func exitDiagnostic() -> String {
    stderrLock.lock()
    let tail = String(data: stderrTail, encoding: .utf8) ?? ""
    stderrLock.unlock()

    let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return "the server exited without saying why"
    }
    return String(trimmed.suffix(400))
  }
}

/// One-way "the watchdog fired", readable from the thread that was blocked.
private final class ExpiryFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  var isSet: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func mark() {
    lock.lock()
    value = true
    lock.unlock()
  }
}

extension Bundle {
  fileprivate var shortVersionString: String {
    (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
  }
}
