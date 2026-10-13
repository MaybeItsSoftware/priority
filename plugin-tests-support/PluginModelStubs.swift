import Foundation

// Fakes for the app-only services (`CheckvistSession`,
// `CheckvistTaskRepository`, `GoogleOAuthLoopbackReceiver`)
// that the plugin code references directly. The classes here share the name
// of the real services so `TaktPlugins` compiles the same plugin source
// against these in-memory stand-ins, while the Xcode app target compiles
// against the real implementations.
//
// Originally this file also duplicated the data models (`CheckvistTask`,
// `CheckvistNote`, `CheckvistList`, `CheckvistTaskCachePayload`,
// `CheckvistSessionError`). Those were promoted to
// canonical sources under `Takt/Plugins/Native/...` and are now
// compiled into `TaktPlugins` directly — see Phase 5.2 of
// `ARCHITECTURE_IMPROVEMENT_PLAN.md`. The remaining service fakes are still
// here pending a follow-on refactor that introduces protocol seams for the
// services themselves.

@MainActor
final class CheckvistSession {
  var issuedToken = "test-token"
  var nextResponseData = Data()
  var nextResponseStatusCode = 200
  var loginResult = true
  var loginError: Error?
  var requestError: Error?

  private(set) var didClearToken = false
  private(set) var loginCallCount = 0
  private(set) var lastLoginUsername: String?
  private(set) var lastLoginRemoteKey: String?
  private(set) var performRequestCallCount = 0
  private(set) var lastRequestUsername: String?
  private(set) var lastRequestRemoteKey: String?
  private(set) var recordedRequests: [URLRequest] = []

  func clearToken() {
    didClearToken = true
  }

  func login(username: String, remoteKey: String) async throws -> Bool {
    loginCallCount += 1
    lastLoginUsername = username
    lastLoginRemoteKey = remoteKey
    if let loginError {
      throw loginError
    }
    return loginResult
  }

  func performAuthenticatedRequest(
    username: String,
    remoteKey: String,
    _ buildRequest: (String) throws -> URLRequest
  ) async throws -> (Data, HTTPURLResponse) {
    performRequestCallCount += 1
    lastRequestUsername = username
    lastRequestRemoteKey = remoteKey

    if let requestError {
      throw requestError
    }

    let request = try buildRequest(issuedToken)
    recordedRequests.append(request)
    let response = HTTPURLResponse(
      url: request.url ?? URL(string: "https://example.com")!,
      statusCode: nextResponseStatusCode,
      httpVersion: nil,
      headerFields: nil
    )!
    return (nextResponseData, response)
  }
}

final class GoogleOAuthLoopbackReceiver {
  func start() async throws -> URL {
    URL(string: "http://127.0.0.1:8787/google-oauth-callback")!
  }

  func waitForCallback(timeout: TimeInterval) async throws -> URL {
    URL(string: "http://127.0.0.1:8787/google-oauth-callback?code=test&state=test")!
  }

  func stop() {}
}
