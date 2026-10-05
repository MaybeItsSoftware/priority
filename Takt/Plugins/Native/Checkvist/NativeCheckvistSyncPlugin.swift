import Foundation

@MainActor
final class NativeCheckvistSyncPlugin: CheckvistSyncPlugin {
  let pluginIdentifier = "native.checkvist.sync"
  let displayName = "Native Checkvist Sync"
  let pluginDescription = "Connect to Checkvist, load remote workspaces, and upload offline tasks."

  private static let userAgent = "Takt/1.0 (Macintosh; Mac OS X)"
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
    let url = CheckvistEndpoints.lists

    let (data, response) = try await performAuthenticatedRequest(credentials: credentials) { validToken in
      var request = URLRequest(url: url)
      request.httpMethod = "GET"
      request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
      return request
    }

    guard (200...299).contains(response.statusCode) else {
      return []
    }

    let lists = try JSONDecoder().decode([CheckvistList].self, from: data)
    return lists.filter { !($0.archived ?? false) }
  }

  func createList(name: String, credentials: CheckvistCredentials) async throws -> CheckvistList? {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else { return nil }
    let url = CheckvistEndpoints.lists

    let (data, response) = try await performAuthenticatedRequest(credentials: credentials) { validToken in
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
      let encodedName = Self.percentEncodeFormValue(trimmedName)
      request.httpBody = "checklist[name]=\(encodedName)".data(using: .utf8)
      return request
    }

    guard (200...299).contains(response.statusCode) else {
      return nil
    }

    if let decoded = try? JSONDecoder().decode(CheckvistList.self, from: data) {
      return decoded
    }
    if let wrapped = try? JSONDecoder().decode(CheckvistListCreateResponse.self, from: data) {
      return wrapped.checklist
    }
    return nil
  }

  func performTaskAction(
    listId: String,
    taskId: Int,
    action: CheckvistTaskAction,
    credentials: CheckvistCredentials
  ) async throws -> Bool {
    guard let url = CheckvistEndpoints.taskAction(listId: listId, taskId: taskId, action: action.rawValue) else {
      return false
    }

    let (_, response) = try await performAuthenticatedRequest(credentials: credentials) { validToken in
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
      request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
      return request
    }

    return (200...299).contains(response.statusCode)
  }

  func updateTask(
    listId: String,
    taskId: Int,
    content: String?,
    due: String?,
    credentials: CheckvistCredentials
  ) async throws -> Bool {
    var bodyParts: [String] = []
    if let content {
      bodyParts.append("task[content]=\(Self.percentEncodeFormValue(content))")
    }
    if let due {
      bodyParts.append("task[due_date]=\(Self.percentEncodeFormValue(due))")
    }
    guard !bodyParts.isEmpty else { return true }
    // Never send parse=true for updates.  Checkvist's server-side parser
    // extracts inline #tags and due markers from the content text, which
    // conflicts with our client-side tag/due management — it strips tags
    // from the stored content and can overwrite explicitly-set due dates.
    return try await putTaskFormEncoded(
      listId: listId,
      taskId: taskId,
      bodyParts: bodyParts,
      includeParseFlag: false,
      credentials: credentials
    )
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
    guard let url = CheckvistEndpoints.tasks(listId: listId) else {
      return nil
    }

    var bodyParts = ["task[content]=\(Self.percentEncodeFormValue(trimmedContent))"]
    if let parentId {
      bodyParts.append("task[parent_id]=\(parentId)")
    }
    if let position {
      bodyParts.append("task[position]=\(position)")
    }

    let (data, response) = try await performAuthenticatedRequest(credentials: credentials) { validToken in
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
      request.httpBody = bodyParts.joined(separator: "&").data(using: .utf8)
      return request
    }

    guard (200...299).contains(response.statusCode) else {
      return nil
    }

    let decoder = JSONDecoder()
    if let task = try? decoder.decode(CheckvistTask.self, from: data) {
      return task
    }
    if let wrapped = try? decoder.decode(CheckvistTaskCreateResponse.self, from: data) {
      return wrapped.task
    }
    if let wrappedList = try? decoder.decode(CheckvistTaskListResponse.self, from: data) {
      return wrappedList.tasks.first
    }
    if let taskList = try? decoder.decode([CheckvistTask].self, from: data) {
      return taskList.first
    }
    return nil
  }

  func deleteTask(listId: String, taskId: Int, credentials: CheckvistCredentials) async throws
    -> Bool
  {
    guard let url = CheckvistEndpoints.task(listId: listId, taskId: taskId) else {
      return false
    }

    let (_, response) = try await performAuthenticatedRequest(credentials: credentials) { validToken in
      var request = URLRequest(url: url)
      request.httpMethod = "DELETE"
      request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
      request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
      return request
    }

    return (200...299).contains(response.statusCode)
  }

  func moveTask(
    listId: String,
    taskId: Int,
    position: Int,
    credentials: CheckvistCredentials
  ) async throws -> Bool {
    try await putTask(
      listId: listId,
      taskId: taskId,
      bodyTaskPayload: ["position": position],
      credentials: credentials
    )
  }

  func reparentTask(
    listId: String,
    taskId: Int,
    parentId: Int?,
    credentials: CheckvistCredentials
  ) async throws -> Bool {
    let payload: [String: Any] = ["parent_id": parentId ?? NSNull()]
    return try await putTask(
      listId: listId,
      taskId: taskId,
      bodyTaskPayload: payload,
      credentials: credentials
    )
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

  private func putTask(
    listId: String,
    taskId: Int,
    bodyTaskPayload: [String: Any],
    includeParseFlag: Bool = false,
    credentials: CheckvistCredentials
  ) async throws -> Bool {
    guard let baseURL = CheckvistEndpoints.task(listId: listId, taskId: taskId) else {
      return false
    }
    let url: URL
    if includeParseFlag, var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) {
      var items = components.queryItems ?? []
      items.append(URLQueryItem(name: "parse", value: "true"))
      components.queryItems = items
      url = components.url ?? baseURL
    } else {
      url = baseURL
    }

    let (_, response) = try await performAuthenticatedRequest(credentials: credentials) { validToken in
      var request = URLRequest(url: url)
      request.httpMethod = "PUT"
      request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
      var requestPayload: [String: Any] = ["task": bodyTaskPayload]
      if includeParseFlag {
        requestPayload["parse"] = true
      }
      request.httpBody = try? JSONSerialization.data(withJSONObject: requestPayload)
      return request
    }

    return (200...299).contains(response.statusCode)
  }

  private func putTaskFormEncoded(
    listId: String,
    taskId: Int,
    bodyParts: [String],
    includeParseFlag: Bool = false,
    credentials: CheckvistCredentials
  ) async throws -> Bool {
    guard let baseURL = CheckvistEndpoints.task(listId: listId, taskId: taskId) else {
      return false
    }
    let url: URL
    if includeParseFlag, var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) {
      var items = components.queryItems ?? []
      items.append(URLQueryItem(name: "parse", value: "true"))
      components.queryItems = items
      url = components.url ?? baseURL
    } else {
      url = baseURL
    }

    let (_, response) = try await performAuthenticatedRequest(credentials: credentials) { validToken in
      var request = URLRequest(url: url)
      request.httpMethod = "PUT"
      request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
      request.httpBody = bodyParts.joined(separator: "&").data(using: .utf8)
      return request
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

  private static func percentEncodeFormValue(_ raw: String) -> String {
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    // Force-unwrap is safe: addingPercentEncoding only returns nil for invalid UTF-16
    // surrogates, which Swift's String type cannot represent.
    return raw.addingPercentEncoding(withAllowedCharacters: allowed)!
  }
}

private struct CheckvistListCreateResponse: Decodable {
  let checklist: CheckvistList
}

private struct CheckvistTaskCreateResponse: Decodable {
  let task: CheckvistTask
}

private struct CheckvistTaskListResponse: Decodable {
  let tasks: [CheckvistTask]
}
