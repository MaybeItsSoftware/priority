import Foundation
import TaktRustCore

@MainActor
final class NativeCheckvistSyncPlugin: CheckvistSyncPlugin {
  let pluginIdentifier = "native.checkvist.sync"
  let displayName = "Native Checkvist Sync"
  let pluginDescription = "Connect to Checkvist, load remote workspaces, and upload offline tasks."

  private let session: CheckvistSession
  private let taskRepository: CheckvistTaskRepository
  private let credentialStore: CheckvistCredentialStore

  init(
    session: CheckvistSession,
    taskRepository: CheckvistTaskRepository,
    credentialStore: CheckvistCredentialStore = CheckvistCredentialStore()
  ) {
    self.session = session
    self.taskRepository = taskRepository
    self.credentialStore = credentialStore
  }

  convenience init() {
    self.init(
      session: CheckvistSession(),
      taskRepository: CheckvistTaskRepository(),
      credentialStore: CheckvistCredentialStore()
    )
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

  func fetchOpenTasks(listId: String, credentials: CheckvistCredentials) async throws
    -> [CheckvistTask]
  {
    try await taskRepository.fetchTasks(
      listId: listId,
      performAuthenticatedRequest: { [weak self] buildRequest in
        guard let self else {
          throw CheckvistSessionError.authenticationUnavailable
        }
        return try await self.performAuthenticatedRequest(
          credentials: credentials,
          buildRequest
        )
      }
    )
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

  func createList(name: String, credentials: CheckvistCredentials) async throws -> CheckvistList? {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else { return nil }

    let (data, response) = try await performAuthenticatedRequest(credentials: credentials) { validToken in
      try CheckvistWire.request(.createList(name: trimmedName), token: validToken)
    }

    guard (200...299).contains(response.statusCode) else {
      return nil
    }
    return checkvistCreatedList(body: CheckvistWire.text(data)).map(CheckvistList.init(core:))
  }

  func performTaskAction(
    listId: String,
    taskId: Int,
    action: CheckvistTaskAction,
    credentials: CheckvistCredentials
  ) async throws -> Bool {
    try await succeeds(
      .taskAction(listId: listId, taskId: Int64(taskId), action: action.rawValue), credentials: credentials)
  }

  func updateTask(
    listId: String,
    taskId: Int,
    content: String?,
    due: String?,
    credentials: CheckvistCredentials
  ) async throws -> Bool {
    guard content != nil || due != nil else { return true }
    // Never parsed: Checkvist's parser would lift inline #tags and due markers
    // out of the content, which conflicts with the app's own tag and due
    // handling — it strips tags from the stored content and can overwrite an
    // explicitly set due date. The core never asks for it on an update.
    return try await succeeds(
      .updateTask(listId: listId, taskId: Int64(taskId), content: content, due: due, tags: nil),
      credentials: credentials)
  }

  func createTask(
    listId: String,
    content: String,
    parentId: Int?,
    position: Int?,
    credentials: CheckvistCredentials
  ) async throws -> CheckvistTask? {
    let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedContent.isEmpty else { return nil }
    let call = CheckvistCall.createTask(
      listId: listId, content: trimmedContent, parentId: parentId.map(Int64.init),
      position: position.map(Int64.init), due: nil, tags: nil, priority: nil, parse: false)
    guard (try? CheckvistWire.request(call, token: nil)) != nil else { return nil }

    let (data, response) = try await performAuthenticatedRequest(credentials: credentials) { validToken in
      try CheckvistWire.request(call, token: validToken)
    }

    guard (200...299).contains(response.statusCode) else {
      return nil
    }
    return checkvistCreatedTask(body: CheckvistWire.text(data)).map(CheckvistTask.init(core:))
  }

  func deleteTask(listId: String, taskId: Int, credentials: CheckvistCredentials) async throws
    -> Bool
  {
    try await succeeds(.deleteTask(listId: listId, taskId: Int64(taskId)), credentials: credentials)
  }

  func moveTask(
    listId: String,
    taskId: Int,
    position: Int,
    credentials: CheckvistCredentials
  ) async throws -> Bool {
    try await succeeds(
      .moveTask(listId: listId, taskId: Int64(taskId), position: Int64(position)), credentials: credentials)
  }

  func reparentTask(
    listId: String,
    taskId: Int,
    parentId: Int?,
    credentials: CheckvistCredentials
  ) async throws -> Bool {
    try await succeeds(
      .reparentTask(listId: listId, taskId: Int64(taskId), parentId: parentId.map(Int64.init)),
      credentials: credentials)
  }

  func persistTaskCache(listId: String, tasks: [CheckvistTask]) {
    taskRepository.persistTaskCache(
      CheckvistTaskCachePayload(listId: listId, fetchedAt: Date(), tasks: tasks)
    )
  }

  func loadTaskCache(for listId: String) -> CheckvistTaskCachePayload? {
    taskRepository.loadTaskCache(for: listId)
  }

  func isTaskCacheOutdated(_ payload: CheckvistTaskCachePayload) -> Bool {
    taskRepository.isCacheOutdated(payload)
  }

  /// Sends `call` and answers whether Checkvist accepted it. A call the
  /// core refuses to make (a list id that is not a number) is not sent.
  private func succeeds(_ call: CheckvistCall, credentials: CheckvistCredentials) async throws -> Bool {
    guard (try? CheckvistWire.request(call, token: nil)) != nil else { return false }
    let (_, response) = try await performAuthenticatedRequest(credentials: credentials) { validToken in
      try CheckvistWire.request(call, token: validToken)
    }
    return (200...299).contains(response.statusCode)
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
