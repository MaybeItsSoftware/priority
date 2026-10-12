import Foundation
import TaktRustCore

@MainActor
final class NativeCheckvistSyncPlugin: CheckvistSyncPlugin {
  let pluginIdentifier = "native.checkvist.sync"
  let displayName = "Checkvist Import"
  let pluginDescription = "Sign in to Checkvist and copy its lists into the workspace."

  private let session: CheckvistSession
  private let credentialStore: CheckvistCredentialStore

  init(
    session: CheckvistSession,
    credentialStore: CheckvistCredentialStore = CheckvistCredentialStore()
  ) {
    self.session = session
    self.credentialStore = credentialStore
  }

  convenience init() {
    self.init(session: CheckvistSession(), credentialStore: CheckvistCredentialStore())
  }

  func startupRemoteKey(useKeychainStorageAtInit: Bool) -> String {
    credentialStore.startupRemoteKey(useKeychainStorageAtInit: useKeychainStorageAtInit)
  }

  func persistRemoteKey(_ value: String, useKeychainStorage: Bool) -> String? {
    credentialStore.persistRemoteKey(value, useKeychainStorage: useKeychainStorage)
  }

  func persistRemoteKeyForDebugStorageMode(_ value: String) {
    credentialStore.persistRemoteKeyForDebugStorageMode(value)
  }

  func loadRemoteKeyFromKeychain() -> String? {
    credentialStore.loadRemoteKeyFromKeychain()
  }

  func clearAuthentication() {
    session.clearToken()
  }

  func login(credentials: CheckvistCredentials) async throws -> Bool {
    guard
      !credentials.normalizedUsername.isEmpty,
      !credentials.normalizedRemoteKey.isEmpty
    else {
      return false
    }
    return try await session.login(
      username: credentials.normalizedUsername,
      remoteKey: credentials.normalizedRemoteKey
    )
  }

  /// A list's open tasks, parents before their children, read by the core.
  func fetchOpenTasks(listId: String, credentials: CheckvistCredentials) async throws
    -> [CheckvistTask]
  {
    let call = CheckvistCall.tasks(listId: listId, withNotes: true)
    guard (try? CheckvistWire.request(call, token: nil)) != nil else {
      throw CheckvistFetchError.invalidListURL
    }
    let (data, response) = try await performAuthenticatedRequest(credentials: credentials) { validToken in
      try CheckvistWire.request(call, token: validToken)
    }
    guard (200...299).contains(response.statusCode) else {
      if response.statusCode == 401 {
        throw CheckvistSessionError.authenticationUnavailable
      }
      throw CheckvistFetchError.fetchFailed(statusCode: response.statusCode)
    }
    return try checkvistTasks(body: CheckvistWire.text(data), includeClosed: false)
      .map(CheckvistTask.init(core:))
  }

  func fetchLists(credentials: CheckvistCredentials) async throws -> [CheckvistList] {
    let (data, response) = try await performAuthenticatedRequest(credentials: credentials) { validToken in
      try CheckvistWire.request(.lists, token: validToken)
    }

    // A failed fetch is a failed fetch, not a user with no lists: returning
    // `[]` here made the repository report success and empty the sidebar.
    guard (200...299).contains(response.statusCode) else {
      if response.statusCode == 401 {
        throw CheckvistSessionError.authenticationUnavailable
      }
      throw CheckvistSessionError.invalidResponse(statusCode: response.statusCode)
    }

    do {
      return try checkvistLists(body: CheckvistWire.text(data)).map(CheckvistList.init(core:))
    } catch {
      throw CheckvistSessionError.invalidResponse(statusCode: response.statusCode)
    }
  }

  private func performAuthenticatedRequest(
    credentials: CheckvistCredentials,
    _ buildRequest: (String) throws -> URLRequest
  ) async throws -> (Data, HTTPURLResponse) {
    try await session.performAuthenticatedRequest(
      username: credentials.normalizedUsername,
      remoteKey: credentials.normalizedRemoteKey,
      buildRequest
    )
  }
}

enum CheckvistFetchError: LocalizedError {
  case invalidListURL
  case fetchFailed(statusCode: Int)

  var errorDescription: String? {
    switch self {
    case .invalidListURL: return "Invalid list URL."
    case .fetchFailed(let statusCode): return "Failed to fetch tasks (HTTP \(statusCode))."
    }
  }
}
