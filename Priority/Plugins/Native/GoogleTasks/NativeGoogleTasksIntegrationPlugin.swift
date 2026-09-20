import Foundation
import Observation
import PriorityCore

/// The transport half of the Google Tasks mirror.
///
/// Deliberately thin: it knows how to ask Google Tasks for lists and tasks and
/// how to create, change and delete them, and nothing whatever about when any
/// of that should happen. Deciding is `GoogleTasksMirror` in `PriorityCore`,
/// which is pure and tested; driving is `GoogleTasksMirrorService`, which owns
/// the workspace and the ledger. Keeping the three apart is what makes the
/// authority rules something you can read rather than infer from HTTP.
@MainActor
@Observable final class NativeGoogleTasksIntegrationPlugin: GoogleTasksIntegrationPlugin {
  let pluginIdentifier = "native.google.tasks.integration"
  let displayName = "Native Google Tasks Integration"
  let pluginDescription =
    "Mirror your lists into Google Tasks, with Priority as the source of authority."

  let account: GoogleAccount

  var isAuthenticating: Bool { account.isAuthenticating }
  var isAuthenticated: Bool { account.hasGrantedScopes(GoogleAPIScope.taskLists) }
  var requiresAuthentication: Bool { account.hasClientConfiguration }
  var hasOAuthClientConfiguration: Bool { account.hasClientConfiguration }

  var oauthClientID: String {
    get { account.clientID }
    set { account.clientID = newValue }
  }

  var authenticationStatusDescription: String {
    guard account.hasClientConfiguration else {
      return "OAuth not configured. Google Tasks is unavailable."
    }
    if account.isAuthenticating { return "Signing in with Google…" }
    if isAuthenticated { return "Connected to the Google Tasks API." }
    // The difference that matters: signed in, but before Tasks was asked for.
    // Saying so points at the fix, which is one more trip through consent.
    if account.isAuthenticated {
      return "Signed in, but this grant predates Google Tasks. Sign in again."
    }
    return "OAuth configured. Sign in required."
  }

  /// Built into absolute strings rather than resolved against a base URL:
  /// `URL(string:relativeTo:)` drops the base's last path component unless it
  /// ends in a slash, which turns `/tasks/v1/lists/…` into `/tasks/lists/…`
  /// and a 404 that only shows up against the real API.
  private static let apiRoot = "https://tasks.googleapis.com/tasks/v1"
  /// Google's ceiling for one page; the mirror pages until the cursor runs out.
  private static let pageSize = 100

  private let session: URLSession

  init(account: GoogleAccount, session: URLSession = .shared) {
    self.account = account
    self.session = session
    account.requireScopes(GoogleAPIScope.taskLists)
  }

  func prepareAuthentication() {
    account.prepare()
  }

  func beginAuthentication() async throws {
    try await account.beginAuthentication()
  }

  func disconnectAuthentication() {
    account.disconnect()
  }

  // MARK: - Lists

  func fetchTaskLists() async throws -> [GoogleTasksMirror.RemoteList] {
    var lists: [GoogleTasksMirror.RemoteList] = []
    var pageToken: String?
    repeat {
      let url = try makeURL("/users/@me/lists", query: pageQuery(pageToken))
      let page = try await send(URLRequest(url: url), as: GoogleTaskListsResponse.self)
      lists += (page.items ?? []).compactMap { item in
        // A list with no id is not a list anyone can write to.
        item.id.map { GoogleTasksMirror.RemoteList(id: $0, title: item.title ?? "Untitled list") }
      }
      pageToken = page.nextPageToken
    } while pageToken != nil
    return lists
  }

  func createTaskList(title: String) async throws -> String {
    let url = try makeURL("/users/@me/lists")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(GoogleTaskListPayload(title: title))
    let created = try await send(request, as: GoogleTaskListResource.self)
    guard let id = created.id else { throw GoogleTasksPluginError.invalidResponse }
    return id
  }

  func renameTaskList(id: String, title: String) async throws {
    var request = URLRequest(url: try makeURL("/users/@me/lists/\(escaped(id))"))
    request.httpMethod = "PATCH"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(GoogleTaskListPayload(title: title))
    _ = try await sendIgnoringBody(request)
  }

  func deleteTaskList(id: String) async throws {
    var request = URLRequest(url: try makeURL("/users/@me/lists/\(escaped(id))"))
    request.httpMethod = "DELETE"
    _ = try await sendIgnoringBody(request)
  }

  // MARK: - Tasks

  /// Everything in the list, including what is finished and what has been
  /// deleted: the planner needs to see a tombstone to tell "ticked off on a
  /// phone" from "never existed".
  func fetchTasks(inList listID: String) async throws -> [GoogleTasksMirror.RemoteTask] {
    var tasks: [GoogleTasksMirror.RemoteTask] = []
    var pageToken: String?
    repeat {
      var query = pageQuery(pageToken)
      query += [
        URLQueryItem(name: "showCompleted", value: "true"),
        URLQueryItem(name: "showDeleted", value: "true"),
        URLQueryItem(name: "showHidden", value: "true"),
      ]
      let url = try makeURL("/lists/\(escaped(listID))/tasks", query: query)
      let page = try await send(URLRequest(url: url), as: GoogleTasksResponse.self)
      tasks += (page.items ?? []).map { $0.asRemoteTask(listID: listID) }
      pageToken = page.nextPageToken
    } while pageToken != nil
    return tasks
  }

  func createTask(inList listID: String, payload: GoogleTasksMirror.TaskPayload) async throws
    -> String
  {
    // `parent` is a query parameter rather than a body field: Google ignores
    // it in the body, which is how a subtask silently becomes a top-level one.
    var query: [URLQueryItem] = []
    if let parent = payload.parentRemoteID {
      query.append(URLQueryItem(name: "parent", value: parent))
    }
    var request = URLRequest(url: try makeURL("/lists/\(escaped(listID))/tasks", query: query))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(GoogleTaskPayload(payload))
    let created = try await send(request, as: GoogleTaskResource.self)
    guard let id = created.id else { throw GoogleTasksPluginError.invalidResponse }
    return id
  }

  func updateTask(id: String, inList listID: String, payload: GoogleTasksMirror.TaskPayload)
    async throws
  {
    var request = URLRequest(url: try makeURL("/lists/\(escaped(listID))/tasks/\(escaped(id))"))
    request.httpMethod = "PATCH"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(GoogleTaskPayload(payload))
    _ = try await sendIgnoringBody(request)
  }

  func deleteTask(id: String, inList listID: String) async throws {
    var request = URLRequest(url: try makeURL("/lists/\(escaped(listID))/tasks/\(escaped(id))"))
    request.httpMethod = "DELETE"
    _ = try await sendIgnoringBody(request)
  }

  // MARK: - Request plumbing

  static func makeURL(root: String, _ path: String, query: [URLQueryItem]) throws -> URL {
    guard var components = URLComponents(string: root + path) else {
      throw GoogleTasksPluginError.invalidResponse
    }
    if !query.isEmpty { components.queryItems = query }
    guard let url = components.url else { throw GoogleTasksPluginError.invalidResponse }
    return url
  }

  private func makeURL(_ path: String, query: [URLQueryItem] = []) throws -> URL {
    try Self.makeURL(root: Self.apiRoot, path, query: query)
  }

  private func escaped(_ identifier: String) -> String {
    identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? identifier
  }

  private func pageQuery(_ pageToken: String?) -> [URLQueryItem] {
    var query = [URLQueryItem(name: "maxResults", value: String(Self.pageSize))]
    if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
    return query
  }

  private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
    try JSONDecoder().decode(T.self, from: try await sendIgnoringBody(request))
  }

  /// Signs, sends, and turns Google's failures into this plugin's errors. A
  /// 401 invalidates the shared sign-in rather than this integration alone:
  /// the token it rejected is the one Calendar is using too.
  @discardableResult
  private func sendIgnoringBody(_ request: URLRequest) async throws -> Data {
    var request = request
    let token = try await account.accessToken(
      requiring: GoogleAPIScope.taskLists, service: "Google Tasks")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw GoogleTasksPluginError.invalidResponse
    }
    if http.statusCode == 401 {
      account.invalidateAfterUnauthorized()
      throw GoogleAccountError.authenticationRequired
    }
    // A mirror races itself: a list or task deleted between the read and the
    // write is the write already having happened, not a failure.
    if http.statusCode == 404 || http.statusCode == 410 {
      throw GoogleTasksPluginError.alreadyGone
    }
    guard (200...299).contains(http.statusCode) else {
      throw GoogleTasksPluginError.apiError(
        String(data: data, encoding: .utf8) ?? "Unknown Google Tasks API error.")
    }
    return data
  }
}

// MARK: - Wire types

private struct GoogleTaskListPayload: Encodable {
  let title: String
}

private struct GoogleTaskPayload: Encodable {
  let title: String
  let notes: String?
  let due: String?
  let status: String

  init(_ payload: GoogleTasksMirror.TaskPayload) {
    self.title = payload.title
    // An empty string rather than nil: omitting the field leaves Google's copy
    // as it was, which would make "the note was cleared in Priority" the one
    // local edit the mirror could not push.
    self.notes = payload.notes
    self.due = payload.due
    self.status = payload.isCompleted ? "completed" : "needsAction"
  }
}

private struct GoogleTaskResource: Decodable {
  let id: String?
  let title: String?
  let notes: String?
  let due: String?
  let status: String?
  let deleted: Bool?
  let parent: String?

  func asRemoteTask(listID: String) -> GoogleTasksMirror.RemoteTask {
    GoogleTasksMirror.RemoteTask(
      id: id ?? "",
      listID: listID,
      parentID: parent,
      title: title ?? "",
      notes: notes ?? "",
      due: due,
      isCompleted: status == "completed",
      isDeleted: deleted ?? false)
  }
}

private struct GoogleTaskListResource: Decodable {
  let id: String?
  let title: String?
}

private struct GoogleTasksResponse: Decodable {
  let items: [GoogleTaskResource]?
  let nextPageToken: String?
}

private struct GoogleTaskListsResponse: Decodable {
  let items: [GoogleTaskListResource]?
  let nextPageToken: String?
}

enum GoogleTasksPluginError: LocalizedError, Equatable {
  /// The thing being changed is not there any more. Expected during a mirror
  /// pass, and handled rather than reported.
  case alreadyGone
  case invalidResponse
  case apiError(String)

  var errorDescription: String? {
    switch self {
    case .alreadyGone:
      return "That Google Tasks item no longer exists."
    case .invalidResponse:
      return "Received an invalid response from Google."
    case .apiError(let message):
      return "Google Tasks API error: \(message)"
    }
  }
}
