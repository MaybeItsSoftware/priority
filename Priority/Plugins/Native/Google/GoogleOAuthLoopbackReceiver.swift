import Foundation
import Network

enum GoogleOAuthLoopbackError: LocalizedError {
  case listenerUnavailable
  case listenerCancelled
  case timedOut
  case invalidCallbackRequest

  var errorDescription: String? {
    switch self {
    case .listenerUnavailable:
      return "Could not start local OAuth callback listener."
    case .listenerCancelled:
      return "Google sign-in was cancelled."
    case .timedOut:
      return "Google sign-in timed out. Try again."
    case .invalidCallbackRequest:
      return "Received an invalid OAuth callback."
    }
  }
}

final class GoogleOAuthLoopbackReceiver: @unchecked Sendable {
  private let callbackPath: String
  private let maxConnections = 10
  private let queue = DispatchQueue(label: "uk.co.maybeitsadam.priority.google-oauth-loopback")
  private var listener: NWListener?
  private var readyContinuation: CheckedContinuation<NWEndpoint.Port, Error>?
  private var callbackContinuation: CheckedContinuation<URL, Error>?
  private var didResolveReady = false
  private var didResolveCallback = false
  private var pendingCallbackResult: Result<URL, Error>?
  private var connectionCount = 0

  init(callbackPath: String = "/google-oauth-callback") {
    self.callbackPath = callbackPath
  }

  func start() async throws -> URL {
    // Bind to loopback explicitly. `NWListener(using: .tcp, on: .any)` only
    // pins the *port* to "pick one for me" and leaves the listener reachable on
    // every interface, which needlessly exposes the callback endpoint to the
    // local network for the duration of sign-in.
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    let listener = try NWListener(using: parameters)
    self.listener = listener
    didResolveReady = false
    didResolveCallback = false
    pendingCallbackResult = nil

    listener.newConnectionHandler = { [weak self] connection in
      self?.handle(connection)
    }

    listener.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        self.resolveReady(with: listener.port)
      case .failed(let error):
        self.resolveReady(with: error)
      case .cancelled:
        self.resolveReady(with: GoogleOAuthLoopbackError.listenerCancelled)
      default:
        break
      }
    }

    let port = try await withCheckedThrowingContinuation { continuation in
      queue.async {
        self.readyContinuation = continuation
        listener.start(queue: self.queue)
      }
    }

    guard let redirectURL = URL(string: "http://127.0.0.1:\(port.rawValue)\(callbackPath)") else {
      throw GoogleOAuthLoopbackError.listenerUnavailable
    }
    return redirectURL
  }

  func waitForCallback(timeout: TimeInterval) async throws -> URL {
    try await withThrowingTaskGroup(of: URL.self) { group in
      group.addTask { [weak self] in
        guard let self else { throw GoogleOAuthLoopbackError.listenerUnavailable }
        return try await withCheckedThrowingContinuation { continuation in
          self.queue.async {
            if let pending = self.pendingCallbackResult {
              self.pendingCallbackResult = nil
              continuation.resume(with: pending)
              return
            }
            self.callbackContinuation = continuation
          }
        }
      }

      group.addTask {
        let ns = UInt64((max(timeout, 0.1) * 1_000_000_000).rounded())
        try await Task.sleep(nanoseconds: ns)
        throw GoogleOAuthLoopbackError.timedOut
      }

      guard let callbackURL = try await group.next() else {
        throw GoogleOAuthLoopbackError.timedOut
      }
      group.cancelAll()
      return callbackURL
    }
  }

  func stop() {
    queue.async {
      self.listener?.cancel()
      self.listener = nil
      self.resolveCallback(with: GoogleOAuthLoopbackError.listenerCancelled)
    }
  }

  private func handle(_ connection: NWConnection) {
    connectionCount += 1
    guard connectionCount <= maxConnections else {
      connection.cancel()
      return
    }
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, _, receiveError in
      guard let self else { return }

      if let receiveError {
        self.sendResponse(
          connection: connection,
          status: "500 Internal Server Error",
          body: "OAuth callback failed: \(receiveError.localizedDescription)"
        )
        self.resolveCallback(with: receiveError)
        return
      }

      guard let data, let rawRequest = String(data: data, encoding: .utf8),
        let callbackURL = self.extractCallbackURL(from: rawRequest)
      else {
        self.sendResponse(
          connection: connection,
          status: "400 Bad Request",
          body: "Invalid OAuth callback request."
        )
        return
      }

      self.sendResponse(
        connection: connection,
        status: "200 OK",
        body: "Google sign-in complete. You can close this tab and return to Priority."
      )
      self.resolveCallback(with: callbackURL)
      // Stop accepting further connections after a successful callback.
      self.listener?.cancel()
      self.listener = nil
    }
  }

  private func extractCallbackURL(from rawRequest: String) -> URL? {
    guard
      let firstLine = rawRequest.components(separatedBy: .newlines).first?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    else { return nil }

    let components = firstLine.split(separator: " ")
    guard components.count >= 2, components[0] == "GET" else { return nil }
    let requestTarget = String(components[1])
    guard requestTarget.hasPrefix(callbackPath) else { return nil }
    guard let port = listener?.port?.rawValue else { return nil }
    return URL(string: "http://127.0.0.1:\(port)\(requestTarget)")
  }

  private func sendResponse(connection: NWConnection, status: String, body: String) {
    let html =
      """
      <!doctype html>
      <html><head><meta charset="utf-8"><title>Priority</title></head>
      <body style="font-family:-apple-system,system-ui,sans-serif;padding:24px;">
      <p>\(body)</p>
      </body></html>
      """
    let response =
      """
      HTTP/1.1 \(status)\r
      Content-Type: text/html; charset=utf-8\r
      Content-Length: \(html.utf8.count)\r
      Connection: close\r
      \r
      \(html)
      """
    connection.send(
      content: Data(response.utf8),
      completion: .contentProcessed { _ in
        connection.cancel()
      })
  }

  private func resolveReady(with port: NWEndpoint.Port?) {
    guard !didResolveReady else { return }
    didResolveReady = true
    guard let continuation = readyContinuation else { return }
    readyContinuation = nil
    guard let port else {
      continuation.resume(throwing: GoogleOAuthLoopbackError.listenerUnavailable)
      return
    }
    continuation.resume(returning: port)
  }

  private func resolveReady(with error: Error) {
    guard !didResolveReady else { return }
    didResolveReady = true
    guard let continuation = readyContinuation else { return }
    readyContinuation = nil
    continuation.resume(throwing: error)
  }

  private func resolveCallback(with url: URL) {
    guard !didResolveCallback else { return }
    didResolveCallback = true
    if let continuation = callbackContinuation {
      callbackContinuation = nil
      continuation.resume(returning: url)
    } else {
      pendingCallbackResult = .success(url)
    }
  }

  private func resolveCallback(with error: Error) {
    guard !didResolveCallback else { return }
    didResolveCallback = true
    if let continuation = callbackContinuation {
      callbackContinuation = nil
      continuation.resume(throwing: error)
    } else {
      pendingCallbackResult = .failure(error)
    }
  }
}
