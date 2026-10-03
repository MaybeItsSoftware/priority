import Foundation
import OSLog
import PriorityCore

@MainActor
final class CheckvistSession {
  private let logger = Logger(subsystem: "uk.co.maybeitssoftware.takt", category: "checkvist-session")
  private let apiClient: CheckvistAPIClient
  private let userAgent = "Takt/1.0 (Macintosh; Mac OS X)"
  private var token: String?
  /// In-flight login task. Concurrent callers await this instead of firing duplicates.
  private var activeLoginTask: Task<Bool, Never>?
  private var activeLoginGeneration: UInt64 = 0

  init(apiClient: CheckvistAPIClient = CheckvistAPIClient()) {
    self.apiClient = apiClient
  }

  func clearToken() {
    token = nil
  }

  func login(username: String, remoteKey: String) async throws -> Bool {
    // If a login is already in flight, coalesce by awaiting its result.
    if let existing = activeLoginTask {
      return await existing.value
    }

    activeLoginGeneration &+= 1
    let generation = activeLoginGeneration
    let task = Task<Bool, Never> { [weak self] in
      guard let self else { return false }
      return await self.executeLoginRequest(username: username, remoteKey: remoteKey)
    }
    activeLoginTask = task

    let result = await task.value
    // Only clear if this is still the active task (not replaced by a newer login).
    if activeLoginGeneration == generation {
      activeLoginTask = nil
    }
    return result
  }

  func performAuthenticatedRequest(
    username: String,
    remoteKey: String,
    _ buildRequest: (String) throws -> URLRequest
  ) async throws -> (Data, HTTPURLResponse) {
    var retryState = AuthRetryState(hasRetriedAfterUnauthorized: false)

    while true {
      if token == nil {
        let ok = try await login(username: username, remoteKey: remoteKey)
        if !ok {
          throw CheckvistSessionError.authenticationUnavailable
        }
      }

      guard let validToken = token else {
        throw CheckvistSessionError.authenticationUnavailable
      }

      let request = try buildRequest(validToken)
      let (data, response) = try await apiClient.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse else {
        throw CheckvistSessionError.invalidResponse(statusCode: nil)
      }

      if httpResponse.statusCode == 401 {
        token = nil
        let retry = AuthRetryPolicy.decisionForUnauthorized(state: retryState)
        retryState = retry.nextState
        if retry.decision == .retryAuthentication {
          continue
        }
      }

      return (data, httpResponse)
    }
  }

  private func executeLoginRequest(username: String, remoteKey: String) async -> Bool {
    let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedRemoteKey = remoteKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedUsername.isEmpty, !normalizedRemoteKey.isEmpty else {
      return false
    }

    let url = CheckvistEndpoints.login
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

    let body: [String: String] = [
      "username": normalizedUsername,
      "remote_key": normalizedRemoteKey,
    ]

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      let (data, response) = try await apiClient.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
        return false
      }

      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let tokenString = json["token"] as? String
      {
        token = tokenString
        return true
      }

      if let tokenString = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
      {
        token = tokenString
        return true
      }

      logger.warning("Login response could not be parsed as token.")
      return false
    } catch {
      logger.error("Login request failed: \(error.localizedDescription, privacy: .public)")
      return false
    }
  }
}

// `CheckvistSessionError` moved to `CheckvistSessionError.swift` so it can be
// shared with `PriorityPlugins` / `PriorityAppLogic` without the session
// machinery.
