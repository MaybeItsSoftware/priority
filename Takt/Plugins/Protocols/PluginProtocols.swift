import Foundation
import TaktCore

protocol Plugin {
  var pluginIdentifier: String { get }
  var displayName: String { get }
  var pluginDescription: String { get }
}

extension Plugin {
  var pluginDescription: String { "" }
}

struct CheckvistCredentials: Sendable {
  let username: String
  let remoteKey: String

  var normalizedUsername: String {
    username.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var normalizedRemoteKey: String {
    remoteKey.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

enum CheckvistTaskAction: String, Sendable, Codable {
  case close
  case reopen
  case invalidate
}

@MainActor
protocol CheckvistSyncPlugin: Plugin {
  func startupRemoteKey(useKeychainStorageAtInit: Bool) -> String
  /// Returns a user-facing failure description, or `nil` on success. Callers
  /// must surface a non-nil result — see `CheckvistCredentialStore`.
  @discardableResult
  func persistRemoteKey(_ value: String, useKeychainStorage: Bool) -> String?
  func persistRemoteKeyForDebugStorageMode(_ value: String)
  func loadRemoteKeyFromKeychain() -> String?
  func clearAuthentication()
  func login(credentials: CheckvistCredentials) async throws -> Bool
  func fetchOpenTasks(listId: String, credentials: CheckvistCredentials) async throws
    -> [CheckvistTask]
  func fetchLists(credentials: CheckvistCredentials) async throws -> [CheckvistList]
  func createList(name: String, credentials: CheckvistCredentials) async throws -> CheckvistList?
  func performTaskAction(
    listId: String,
    taskId: Int,
    action: CheckvistTaskAction,
    credentials: CheckvistCredentials
  ) async throws -> Bool
  func updateTask(
    listId: String,
    taskId: Int,
    content: String?,
    due: String?,
    credentials: CheckvistCredentials
  ) async throws -> Bool
  func createTask(
    listId: String,
    content: String,
    parentId: Int?,
    position: Int?,
    credentials: CheckvistCredentials
  ) async throws -> CheckvistTask?
  func deleteTask(listId: String, taskId: Int, credentials: CheckvistCredentials) async throws
    -> Bool
  func moveTask(
    listId: String,
    taskId: Int,
    position: Int,
    credentials: CheckvistCredentials
  ) async throws -> Bool
  func reparentTask(
    listId: String,
    taskId: Int,
    parentId: Int?,
    credentials: CheckvistCredentials
  ) async throws -> Bool
  func persistTaskCache(listId: String, tasks: [CheckvistTask])
  func loadTaskCache(for listId: String) -> CheckvistTaskCachePayload?
  func isTaskCacheOutdated(_ payload: CheckvistTaskCachePayload) -> Bool
}

@MainActor
extension CheckvistSyncPlugin {
  func startupRemoteKey(useKeychainStorageAtInit: Bool) -> String {
    ""
  }

  func persistRemoteKey(_ value: String, useKeychainStorage: Bool) -> String? { nil }

  func persistRemoteKeyForDebugStorageMode(_ value: String) {}

  func loadRemoteKeyFromKeychain() -> String? {
    nil
  }

  func createList(name: String, credentials: CheckvistCredentials) async throws -> CheckvistList? {
    nil
  }
}

@MainActor
protocol ObsidianIntegrationPlugin: Plugin {
  var inboxPath: String { get }
  func chooseInboxFolder() throws -> String?
  func clearInboxFolder()
  func chooseLinkedFolder(forTaskId taskId: Int, taskContent: String) throws -> String?
  func createAndLinkFolder(forTaskId taskId: Int, taskContent: String) throws -> String?
  func clearLinkedFolder(forTaskId taskId: Int)
  func hasLinkedFolder(forTaskId taskId: Int) -> Bool
  func hasSyncedNote(task: CheckvistTask, linkedFolderTaskId: Int?) -> Bool
  func syncTask(
    _ task: CheckvistTask,
    listId: String,
    linkedFolderTaskId: Int?,
    openMode: ObsidianOpenMode,
    syncDate: Date
  ) throws -> URL
}

@MainActor
protocol AFFiNEIntegrationPlugin: Plugin {
  /// Whether an `affine-mcp` helper was found. Credentials are the helper's
  /// business — Priority never sees an AFFiNE password — so this is as far as
  /// "configured" goes on this side.
  var isConfigured: Bool { get }
  var serverCommandPath: String { get set }
  var workspaceId: String { get set }
  /// The document a new checklist is filed under, so it appears in the sidebar
  /// rather than only in search.
  var parentDocId: String { get set }
  var resolvedServerCommandPath: String? { get }
  /// Every path searched for the helper, as a message worth showing.
  func helperDiagnostic() -> String
  func availableWorkspaces() async throws -> [AFFiNEWorkspace]
  func selectWorkspace(_ workspace: AFFiNEWorkspace)
  /// Squares a list with its AFFiNE checklist: what was ticked in AFFiNE is
  /// closed through `closingTicked`, and what is still open is written back.
  func syncChecklist(
    tasks: [CheckvistTask],
    listId: String,
    listTitle: String,
    closingTicked: ([Int]) async -> [CheckvistTask]
  ) async throws -> AFFiNEChecklistOutcome
  /// - Parameter renderedSection: the day as `DailyNoteMarkdown` renders it,
  ///   passed in rather than built here so the vault and the workspace show the
  ///   same day.
  func exportDay(_ day: Date, renderedSection: String, titlePattern: String) async throws
    -> AFFiNEDocumentRef
  func checklistDocumentURL(forListId listId: String) -> URL?
  func forgetChecklistDocument(forListId listId: String)
}

@MainActor
protocol GoogleCalendarIntegrationPlugin: Plugin {
  func makeCreateEventURL(task: CheckvistTask, listId: String, now: Date) -> URL?
  func createEvent(task: CheckvistTask, listId: String, now: Date) async throws
    -> GoogleCalendarEventCreationOutcome
  func createEvent(
    title: String, details: String, date: Date?, isAllDay: Bool, now: Date
  ) async throws -> GoogleCalendarEventCreationOutcome
  /// Whether an event Priority created is still on the calendar.
  func eventState(id: String) async throws -> GoogleCalendarEventState
  var requiresAuthentication: Bool { get }
  var isAuthenticated: Bool { get }
  var authenticationStatusDescription: String { get }
  func prepareAuthentication()
  func beginAuthentication() async throws
  func disconnectAuthentication()
}

/// Mirroring Priority's lists into Google Tasks.
///
/// Transport only. What the mirror *should* do is `GoogleTasksMirror` in
/// `TaktCore`; this is the set of moves it is allowed to ask for.
@MainActor
protocol GoogleTasksIntegrationPlugin: Plugin {
  func fetchTaskLists() async throws -> [GoogleTasksMirror.RemoteList]
  func createTaskList(title: String) async throws -> String
  func renameTaskList(id: String, title: String) async throws
  func deleteTaskList(id: String) async throws

  func fetchTasks(inList listID: String) async throws -> [GoogleTasksMirror.RemoteTask]
  func createTask(inList listID: String, payload: GoogleTasksMirror.TaskPayload) async throws
    -> String
  func updateTask(id: String, inList listID: String, payload: GoogleTasksMirror.TaskPayload)
    async throws
  func deleteTask(id: String, inList listID: String) async throws

  var requiresAuthentication: Bool { get }
  var isAuthenticated: Bool { get }
  var authenticationStatusDescription: String { get }
  /// Loads the stored sign-in so `isAuthenticated` is worth reading. Called
  /// before a surface shows the state, never from inside one.
  func prepareAuthentication()
  func beginAuthentication() async throws
  func disconnectAuthentication()
}

struct GoogleCalendarEventCreationOutcome: Sendable {
  let urlToOpen: URL?
  let usedGoogleCalendarAPI: Bool
  /// Google's id for the created event, when one was really created through
  /// the API. It is what lets Priority ask later whether the event is still
  /// there — which is how clearing it off a calendar completes the task.
  var eventID: String?
}

/// What became of an event Priority created.
enum GoogleCalendarEventState: Sendable, Equatable {
  case active
  /// Cancelled or deleted — cleared off the calendar, which is what a person
  /// does to an event once it has happened.
  case gone
}

@MainActor
extension GoogleCalendarIntegrationPlugin {
  func createEvent(task: CheckvistTask, listId: String, now: Date) async throws
    -> GoogleCalendarEventCreationOutcome
  {
    GoogleCalendarEventCreationOutcome(
      urlToOpen: makeCreateEventURL(task: task, listId: listId, now: now),
      usedGoogleCalendarAPI: false
    )
  }

  func createEvent(
    title: String, details: String, date: Date?, isAllDay: Bool, now: Date
  ) async throws -> GoogleCalendarEventCreationOutcome {
    var components = URLComponents(string: "https://calendar.google.com/calendar/render")
    let calendar = Calendar.current
    let start = date ?? now
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    if isAllDay {
      formatter.timeZone = calendar.timeZone
      formatter.dateFormat = "yyyyMMdd"
    } else {
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    }
    let end = calendar.date(
      byAdding: isAllDay ? .day : .minute, value: isAllDay ? 1 : 30, to: start) ?? start
    components?.queryItems = [
      .init(name: "action", value: "TEMPLATE"),
      .init(name: "text", value: title),
      .init(name: "details", value: details),
      .init(name: "dates", value: "\(formatter.string(from: start))/\(formatter.string(from: end))"),
      .init(name: "ctz", value: calendar.timeZone.identifier),
    ]
    return GoogleCalendarEventCreationOutcome(urlToOpen: components?.url, usedGoogleCalendarAPI: false)
  }

  func prepareAuthentication() {}

  /// A plugin with no API behind it never created an event to ask about.
  func eventState(id: String) async throws -> GoogleCalendarEventState { .active }

  var requiresAuthentication: Bool { false }
  var isAuthenticated: Bool { true }
  var authenticationStatusDescription: String {
    "Uses your browser session to create prefilled events."
  }

  func beginAuthentication() async throws {}
  func disconnectAuthentication() {}
}

/// The executable and arguments an MCP client should launch.
struct MCPServerInvocation: Equatable {
  let command: String
  let args: [String]
}

@MainActor
protocol MCPIntegrationPlugin: Plugin {
  func serverCommandURL() -> URL?
  func guideURL() -> URL?
  /// The resolved command, so callers can assemble a client entry themselves
  /// rather than parsing one back out of `makeClientConfigurationJSON`.
  func serverInvocation() -> MCPServerInvocation
  /// The non-secret settings the server process needs, in MCP `env` form.
  /// Credentials are deliberately not among them — the server reads those from
  /// its own store, which the app seeds. See the implementation.
  func serverEnvironment(listId: String) -> [String: String]
  func makeClientConfigurationJSON(listId: String) -> String
}
