import Foundation
import Observation
import PriorityCore
import os

/// One agent thread: the user's own Claude Code, headless, with Priority's MCP
/// server as its only tool — and a person between it and every write.
///
/// The process is `claude -p` in stream-json mode (see `AgentInvocation` for
/// the exact command line and why each flag is there). It stays up for the
/// thread, so a follow-up is one more line on its stdin, and it goes when the
/// thread does: Stop and New thread both end it.
///
/// **The invariant: nothing writes without a click.** The read-only tools are
/// pre-allowed on the command line; every other call stops inside the CLI on
/// a `can_use_tool` control request that only `approve(_:)` answers yes to,
/// and only from a button. There is no timer that answers, no "always allow",
/// and no path that approves on the user's behalf. A request left alone just
/// waits. Stopping the thread, starting a new one, quitting the app or the
/// process dying all withdraw it — the CLI that asked is gone, so the call it
/// asked about can never run.
@MainActor
@Observable final class WorkspaceAgentSession {
  private static let log = Logger(subsystem: "uk.co.maybeitssoftware.takt", category: "WorkspaceAgentSession")

  enum ApprovalState: Equatable {
    case pending
    case approved
    case denied
    /// The thread ended before anyone answered, so the change never ran.
    case withdrawn
  }

  /// What happened to an approved write, once the tool reports back.
  enum Outcome: Equatable {
    case applied
    case failed(String)
  }

  struct Approval: Equatable {
    let request: AgentPermissionRequest
    var state: ApprovalState
    var outcome: Outcome?
  }

  enum Entry: Equatable {
    case user(String)
    case assistant(String)
    /// A pre-allowed read. `failed` is nil until its result arrives.
    case read(AgentToolUse, failed: Bool?)
    case write(Approval)
    case notice(String, isError: Bool)
  }

  struct Item: Identifiable, Equatable {
    let id = UUID()
    var entry: Entry
  }

  private(set) var items: [Item] = []
  /// A turn is under way: a message sent and its `result` not yet back.
  private(set) var isWorking = false
  /// Bumped at the end of every turn, so the workspace can look for the
  /// writes the turn made without waiting for its next poll.
  private(set) var finishedTurns = 0

  /// A path to `claude` set by hand, tried before the usual install locations.
  var userExecutablePath = UserDefaults.standard.string(forKey: AgentCLILocator.userPathDefaultsKey) ?? "" {
    didSet { UserDefaults.standard.set(userExecutablePath, forKey: AgentCLILocator.userPathDefaultsKey) }
  }

  var executableCandidates: [String] {
    AgentCLILocator.candidates(userPath: userExecutablePath, homeDirectory: NSHomeDirectory())
  }

  /// The binary a new thread would launch, or nil when there is none.
  var executablePath: String? {
    AgentCLILocator.resolve(candidates: executableCandidates, isExecutable: FileManager.default.isExecutableFile)
  }

  var pendingApproval: Item? {
    items.first { item in
      if case .write(let approval) = item.entry { return approval.state == .pending }
      return false
    }
  }

  var isRunning: Bool { process != nil }

  @ObservationIgnored private var process: Process?
  @ObservationIgnored private var input: FileHandle?
  @ObservationIgnored private var stderrTail = AgentOutputTail()
  /// Which process a line or an exit belongs to. A thread that was stopped can
  /// still have lines in flight; they are dropped rather than applied to the
  /// thread that replaced it.
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var stoppedOnPurpose = false
  /// Tool-use ids to the item that shows them, for matching results.
  @ObservationIgnored private var toolItems: [String: UUID] = [:]

  // MARK: - The user's side

  /// Sends a message, starting the thread's process first if there is none.
  /// `context` is sent ahead of the text but not shown in the transcript.
  func send(_ text: String, context: String?) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !isWorking, pendingApproval == nil else { return }
    if process == nil {
      guard start() else { return }
    }
    items.append(Item(entry: .user(trimmed)))
    let message = context.map { "\($0)\n\n\(trimmed)" } ?? trimmed
    if write(AgentStreamEncoder.userMessage(message)) { isWorking = true }
  }

  /// Lets one write run, with exactly the input the card showed. Only ever
  /// called from the card's button or its Return key.
  func approve(_ itemID: UUID) {
    answer(itemID) { approval in
      write(AgentStreamEncoder.allow(requestID: approval.request.requestID, input: approval.request.input))
        ? .approved : nil
    }
  }

  func deny(_ itemID: UUID) {
    answer(itemID) { approval in
      write(
        AgentStreamEncoder.deny(
          requestID: approval.request.requestID,
          message: "The user declined this change. Do not retry it; ask what they would like instead."))
      // Denied whether or not the line got through: if the process is gone,
      // the call it asked about is gone with it.
      return .denied
    }
  }

  /// Ends the thread's process. The transcript stays, so what was said can
  /// still be read; the next message starts a fresh process with no memory
  /// of it.
  func stop() {
    guard process != nil else { return }
    let wasWorking = isWorking || pendingApproval != nil
    end()
    if wasWorking { items.append(Item(entry: .notice("Stopped.", isError: false))) }
  }

  /// Ends the thread and clears the transcript.
  func newThread() {
    end()
    items = []
  }

  // MARK: - The process

  /// Launches `claude`. Returns false, with a notice saying why, when it
  /// cannot.
  private func start() -> Bool {
    guard let executable = executablePath else {
      items.append(Item(entry: .notice("Claude Code was not found. Set its path below.", isError: true)))
      return false
    }
    guard let helper = Self.mcpHelperPath() else {
      items.append(
        Item(
          entry: .notice(
            "Takt's MCP server is missing from this build (Contents/Helpers/takt), so the "
              + "assistant would have no tools. Build without PRIORITY_SKIP_CLI_BUNDLE, or install the "
              + "CLI with scripts/install_cli.sh.",
            isError: true)))
      return false
    }

    // A write to a pipe whose reader has died raises SIGPIPE, which would
    // take the app down with the child. Ignored, the write fails instead and
    // `write(_:)` reports it.
    signal(SIGPIPE, SIG_IGN)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = AgentInvocation.arguments(
      helperPath: helper, systemPrompt: AgentSystemPrompt.text(today: .now))
    process.currentDirectoryURL = Self.workingDirectory()
    process.environment = Self.environment()

    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr

    generation += 1
    let generation = generation
    let lines = AgentLineBuffer()
    stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let chunk = handle.availableData
      if chunk.isEmpty {
        handle.readabilityHandler = nil
        return
      }
      for line in lines.append(chunk) {
        // The main queue, not a `Task`: it is FIFO, and the order of these
        // lines is the order of the conversation.
        DispatchQueue.main.async {
          MainActor.assumeIsolated { self?.receive(line, generation: generation) }
        }
      }
    }
    let tail = AgentOutputTail()
    stderrTail = tail
    stderr.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      if chunk.isEmpty { handle.readabilityHandler = nil } else { tail.append(chunk) }
    }
    process.terminationHandler = { [weak self] finished in
      let status = finished.terminationStatus
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.processExited(status: status, generation: generation) }
      }
    }

    do {
      try process.run()
    } catch {
      Self.log.error("Could not launch Claude Code: \(error.localizedDescription, privacy: .public)")
      items.append(Item(entry: .notice("Could not start Claude Code: \(error.localizedDescription)", isError: true)))
      return false
    }
    Self.log.info("Started an agent thread with \(executable, privacy: .public)")
    self.process = process
    input = stdin.fileHandleForWriting
    stoppedOnPurpose = false
    return true
  }

  /// Ends the process and withdraws anything still waiting on it.
  private func end() {
    stoppedOnPurpose = true
    try? input?.close()
    process?.terminate()
    process = nil
    input = nil
    isWorking = false
    toolItems = [:]
    withdrawPendingApprovals()
  }

  private func processExited(status: Int32, generation: Int) {
    guard generation == self.generation, process != nil else { return }
    process = nil
    input = nil
    isWorking = false
    withdrawPendingApprovals()
    guard !stoppedOnPurpose else { return }
    let detail = stderrTail.text.trimmingCharacters(in: .whitespacesAndNewlines)
    Self.log.error("Claude Code exited with \(status); stderr: \(detail, privacy: .public)")
    items.append(
      Item(
        entry: .notice(
          detail.isEmpty ? "Claude Code stopped (exit \(status))." : "Claude Code stopped: \(detail)",
          isError: true)))
  }

  private func withdrawPendingApprovals() {
    for index in items.indices {
      if case .write(var approval) = items[index].entry, approval.state == .pending {
        approval.state = .withdrawn
        items[index].entry = .write(approval)
      }
    }
  }

  @discardableResult
  private func write(_ line: String) -> Bool {
    guard let input else { return false }
    do {
      try input.write(contentsOf: Data(line.utf8))
      return true
    } catch {
      Self.log.error("Could not write to Claude Code: \(error.localizedDescription, privacy: .public)")
      return false
    }
  }

  private func answer(_ itemID: UUID, _ reply: (Approval) -> ApprovalState?) {
    guard let index = items.firstIndex(where: { $0.id == itemID }),
      case .write(var approval) = items[index].entry, approval.state == .pending
    else { return }
    guard process != nil else {
      approval.state = .withdrawn
      items[index].entry = .write(approval)
      return
    }
    guard let state = reply(approval) else { return }
    approval.state = state
    items[index].entry = .write(approval)
  }

  // MARK: - What the CLI says

  private func receive(_ line: String, generation: Int) {
    guard generation == self.generation else { return }
    for event in AgentStreamParser.events(fromLine: line) {
      handle(event)
    }
  }

  private func handle(_ event: AgentStreamEvent) {
    switch event {
    case .started(let session, let model, _):
      Self.log.info("Agent session \(session, privacy: .public) on \(model ?? "the default model", privacy: .public)")

    case .text(let text):
      items.append(Item(entry: .assistant(text)))

    case .toolUse(let use):
      // Reads get a line of their own. A write's card is drawn by its
      // permission request, which follows.
      guard AgentToolPolicy.isReadOnly(use.name) else { return }
      let item = Item(entry: .read(use, failed: nil))
      toolItems[use.id] = item.id
      items.append(item)

    case .toolResult(let toolUseID, let isError, let text):
      guard let itemID = toolItems[toolUseID], let index = items.firstIndex(where: { $0.id == itemID }) else {
        return
      }
      switch items[index].entry {
      case .read(let use, _):
        items[index].entry = .read(use, failed: isError)
      case .write(var approval) where approval.state == .approved:
        approval.outcome = isError ? .failed(text) : .applied
        items[index].entry = .write(approval)
      default:
        break
      }

    case .permissionRequest(let request):
      switch AgentToolPolicy.decision(forPermissionRequestOn: request.toolName) {
      case .refuse:
        write(
          AgentStreamEncoder.deny(
            requestID: request.requestID, message: "Only Takt's own tools are available here."))
        items.append(Item(entry: .notice("Refused \(request.toolName): not one of Takt's tools.", isError: true)))
      case .askUser:
        let item = Item(entry: .write(Approval(request: request, state: .pending, outcome: nil)))
        if let toolUseID = request.toolUseID { toolItems[toolUseID] = item.id }
        items.append(item)
      }

    case .unsupportedControlRequest(let requestID, let subtype):
      write(AgentStreamEncoder.error(requestID: requestID, message: "Takt does not handle \(subtype)."))

    case .controlRequestCancelled(let requestID):
      for index in items.indices {
        if case .write(var approval) = items[index].entry, approval.state == .pending,
          approval.request.requestID == requestID
        {
          approval.state = .withdrawn
          items[index].entry = .write(approval)
        }
      }

    case .turnFinished(let result):
      isWorking = false
      finishedTurns += 1
      if result.isError {
        let detail = result.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        items.append(
          Item(entry: .notice(detail.isEmpty ? "The turn ended with \(result.subtype)." : detail, isError: true)))
      }
    }
  }

  // MARK: - Where things are

  /// The bundled MCP helper, found the way `Priority --mcp-server` finds it.
  private static func mcpHelperPath() -> String? {
    let candidates = MCPHelperLocator.candidates(
      environmentOverride: ProcessInfo.processInfo.environment["PRIORITY_MCP_EXECUTABLE_PATH"],
      bundlePath: Bundle.main.bundlePath,
      homeDirectory: NSHomeDirectory())
    return MCPHelperLocator.resolve(candidates: candidates, isExecutable: FileManager.default.isExecutableFile)
  }

  /// An empty directory of the app's own, so no project's `CLAUDE.md` or
  /// `.mcp.json` is picked up from wherever the app happened to launch.
  private static func workingDirectory() -> URL {
    let directory = AppIdentity.applicationSupportDirectory()
      .appendingPathComponent("Agent", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// The app's environment with a usable `PATH` — a GUI app's is the bare
  /// system one — and without the markers that tell Claude Code it is
  /// running inside another Claude Code session, which it would be if the
  /// app was launched from one.
  private static func environment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    let home = NSHomeDirectory()
    environment["PATH"] = [
      "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ].joined(separator: ":")
    for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"] {
      environment[key] = nil
    }
    return environment
  }
}

/// Splits a byte stream into lines. Touched only from the pipe's reader, one
/// chunk at a time, but locked so that is not something to take on trust.
private final class AgentLineBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var pending = Data()

  func append(_ chunk: Data) -> [String] {
    lock.lock()
    defer { lock.unlock() }
    pending.append(chunk)
    var lines: [String] = []
    while let newline = pending.firstIndex(of: 0x0A) {
      let line = pending[pending.startIndex..<newline]
      pending.removeSubrange(pending.startIndex...newline)
      if let text = String(bytes: line, encoding: .utf8) { lines.append(text) }
    }
    return lines
  }
}

/// The last few kilobytes of stderr, to say why a process died.
private final class AgentOutputTail: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()

  func append(_ chunk: Data) {
    lock.lock()
    data.append(chunk)
    if data.count > 4096 { data.removeFirst(data.count - 4096) }
    lock.unlock()
  }

  var text: String {
    lock.lock()
    defer { lock.unlock() }
    return String(bytes: data, encoding: .utf8) ?? ""
  }
}
