import Foundation
import OSLog
import TaktCore

@MainActor
final class CheckvistSession {
  /// What one login attempt established. Kept apart from the `Bool` that
  /// `login` returns so a caller can tell "Checkvist said no" from "Checkvist
  /// could not be reached" — the first is the user's credentials, the second
  /// is not.
  private enum LoginOutcome {
    case authenticated
    case rejected
    case failed(CheckvistSessionError)
  }

  private let logger = Logger(subsystem: "uk.co.maybeitssoftware.takt", category: "checkvist-session")
  private let apiClient: CheckvistAPIClient
  private var token: String?
  /// The credentials `token` was issued for. A login with different ones
  /// cannot reuse it.
  private var tokenCredentials: (username: String, remoteKey: String)?
  /// In-flight login task. Concurrent callers await this instead of firing duplicates.
  private var activeLoginTask: Task<LoginOutcome, Never>?

  init(apiClient: CheckvistAPIClient = CheckvistAPIClient()) {
    self.apiClient = apiClient
  }

  func clearToken() {
    token = nil
    tokenCredentials = nil
  }

  /// True once signed in, false when Checkvist rejected the credentials.
  /// Throws `requestFailed` when Checkvist could not be reached and
  /// `invalidResponse` when it answered with something other than a token,
  /// so that neither is reported to the user as "check your credentials".
  func login(username: String, remoteKey: String) async throws -> Bool {
    let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedRemoteKey = remoteKey.trimmingCharacters(in: .whitespacesAndNewlines)

    // Already signed in as this user: nothing to ask Checkvist.
    if token != nil, let issuedFor = tokenCredentials,
      issuedFor.username == normalizedUsername, issuedFor.remoteKey == normalizedRemoteKey
    {
      return true
    }

    // If a login is already in flight, coalesce by awaiting its result.
    if let existing = activeLoginTask {
      return try Self.result(of: await existing.value)
    }

    let task = Task<LoginOutcome, Never> { [weak self] in
      guard let self else { return .failed(.authenticationUnavailable) }
      return await self.executeLoginRequest(username: normalizedUsername, remoteKey: normalizedRemoteKey)
    }
    activeLoginTask = task

    let outcome = await task.value
    // Nothing can have replaced it: a login arriving while this one was in
    // flight awaited it above rather than starting its own.
    activeLoginTask = nil
    return try Self.result(of: outcome)
  }

  private static func result(of outcome: LoginOutcome) throws -> Bool {
    switch outcome {
    case .authenticated: return true
    case .rejected: return false
    case .failed(let error): throw error
    }
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
        clearToken()
        let retry = AuthRetryPolicy.decisionForUnauthorized(state: retryState)
        retryState = retry.nextState
        if retry.decision == .retryAuthentication {
          continue
        }
      }

      return (data, httpResponse)
    }
  }

  /// Runs the login request. On success the token is stored here, on the
  /// actor, so coalesced callers all see the same session.
  private func executeLoginRequest(username: String, remoteKey: String) async -> LoginOutcome {
    guard !username.isEmpty, !remoteKey.isEmpty else {
      return .rejected
    }

    let url = CheckvistEndpoints.login
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(CheckvistEndpoints.userAgent, forHTTPHeaderField: "User-Agent")

    let body: [String: String] = [
      "username": username,
      "remote_key": remoteKey,
    ]

    let data: Data
    let httpResponse: HTTPURLResponse
    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      let (responseData, response) = try await apiClient.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        return .failed(.invalidResponse(statusCode: nil))
      }
      data = responseData
      httpResponse = http
    } catch {
      logger.error("Login request failed: \(error.localizedDescription, privacy: .public)")
      return .failed(.requestFailed(underlying: error))
    }

    switch httpResponse.statusCode {
    case 200...299:
      break
    case 401, 403:
      return .rejected
    default:
      return .failed(.invalidResponse(statusCode: httpResponse.statusCode))
    }

    guard let issued = Self.token(in: data) else {
      logger.warning("Login response could not be parsed as token.")
      return .failed(.invalidResponse(statusCode: httpResponse.statusCode))
    }
    token = issued
    tokenCredentials = (username: username, remoteKey: remoteKey)
    return .authenticated
  }

  /// The token in a login response body: `{"token": "…"}` or the bare
  /// (possibly quoted) string. An empty string is not a token.
  private static func token(in data: Data) -> String? {
    let candidate: String?
    if let object = try? JSONSerialization.jsonObject(with: data) {
      candidate = (object as? [String: Any])?["token"] as? String
    } else {
      candidate = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
    }
    guard let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return candidate
  }
}

// `CheckvistSessionError` moved to `CheckvistSessionError.swift` so it can be
// shared with `TaktPlugins` / `TaktAppLogic` without the session
// machinery.
