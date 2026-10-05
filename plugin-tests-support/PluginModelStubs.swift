import Foundation

// Fakes for the four app-only services (`ObsidianSyncService`,
// `CheckvistSession`, `CheckvistTaskRepository`, `GoogleOAuthLoopbackReceiver`)
// that the plugin code references directly. The classes here share the name
// of the real services so `TaktPlugins` compiles the same plugin source
// against these in-memory stand-ins, while the Xcode app target compiles
// against the real implementations.
//
// Originally this file also duplicated the data models (`CheckvistTask`,
// `CheckvistNote`, `CheckvistList`, `CheckvistTaskCachePayload`,
// `ObsidianOpenMode`, `CheckvistSessionError`). Those were promoted to
// canonical sources under `Takt/Plugins/Native/...` and are now
// compiled into `TaktPlugins` directly — see Phase 5.2 of
// `ARCHITECTURE_IMPROVEMENT_PLAN.md`. The remaining service fakes are still
// here pending a follow-on refactor that introduces protocol seams for the
// services themselves.

@MainActor
final class ObsidianSyncService {
  var inboxPath = ""
  var chooseInboxFolderResult: String?
  var chooseLinkedFolderResult: String?
  var createAndLinkFolderResult: String?
  var syncResultURL = URL(fileURLWithPath: "/tmp/obsidian-task.md")
  var syncedNoteTaskIDs: Set<Int> = []
  private var linkedFolderByTask: [Int: String] = [:]

  private(set) var lastSyncCall:
    (
      task: CheckvistTask,
      listId: String,
      linkedFolderTaskId: Int?,
      openMode: ObsidianOpenMode,
      syncDate: Date
    )?

  func chooseInboxFolder() throws -> String? {
    chooseInboxFolderResult
  }

  func clearInboxFolder() {
    inboxPath = ""
  }

  func chooseLinkedFolder(forTaskId taskId: Int, taskContent: String) throws -> String? {
    if let chosen = chooseLinkedFolderResult {
      linkedFolderByTask[taskId] = chosen
    }
    return chooseLinkedFolderResult
  }

  func createAndLinkFolder(forTaskId taskId: Int, taskContent: String) throws -> String? {
    if let created = createAndLinkFolderResult {
      linkedFolderByTask[taskId] = created
    }
    return createAndLinkFolderResult
  }

  func clearLinkedFolder(forTaskId taskId: Int) {
    linkedFolderByTask.removeValue(forKey: taskId)
  }

  func hasLinkedFolder(forTaskId taskId: Int) -> Bool {
    linkedFolderByTask[taskId] != nil
  }

  func hasSyncedNote(task: CheckvistTask, linkedFolderTaskId: Int?) -> Bool {
    syncedNoteTaskIDs.contains(task.id)
  }

  func syncTask(
    _ task: CheckvistTask,
    listId: String,
    linkedFolderTaskId: Int?,
    openMode: ObsidianOpenMode,
    syncDate: Date
  ) throws -> URL {
    lastSyncCall = (task, listId, linkedFolderTaskId, openMode, syncDate)
    return syncResultURL
  }
}

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

@MainActor
final class CheckvistTaskRepository {
  var nextFetchedTasks: [CheckvistTask] = []
  var fetchError: Error?
  var isCacheOutdatedResult = false

  private(set) var fetchTasksCallCount = 0
  private(set) var persistedPayload: CheckvistTaskCachePayload?
  var cachedPayloadByListId: [String: CheckvistTaskCachePayload] = [:]

  func fetchTasks(
    listId: String,
    performAuthenticatedRequest:
      @escaping ((String) throws -> URLRequest) async throws -> (Data, HTTPURLResponse)
  ) async throws -> [CheckvistTask] {
    fetchTasksCallCount += 1
    if let fetchError {
      throw fetchError
    }
    return nextFetchedTasks
  }

  func persistTaskCache(_ payload: CheckvistTaskCachePayload) {
    persistedPayload = payload
    cachedPayloadByListId[payload.listId] = payload
  }

  func loadTaskCache(for listId: String) -> CheckvistTaskCachePayload? {
    cachedPayloadByListId[listId]
  }

  func isCacheOutdated(_ payload: CheckvistTaskCachePayload) -> Bool {
    isCacheOutdatedResult
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
