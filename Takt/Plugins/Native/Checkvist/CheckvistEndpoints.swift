import Foundation

/// Central registry of all Checkvist API and web URLs.
/// Change `baseURL` once to point at a self-hosted or staging instance.
enum CheckvistEndpoints {
  static let baseURL = "https://checkvist.com"

  // MARK: - Static endpoints

  static var login: URL { URL(string: "\(baseURL)/auth/login.json")! }
  static var lists: URL { URL(string: "\(baseURL)/checklists.json")! }

  // MARK: - Dynamic endpoints

  static func tasks(listId: String) -> URL? {
    URL(string: "\(baseURL)/checklists/\(listId)/tasks.json")
  }

  static func task(listId: String, taskId: Int) -> URL? {
    URL(string: "\(baseURL)/checklists/\(listId)/tasks/\(taskId).json")
  }

  static func taskAction(listId: String, taskId: Int, action: String) -> URL? {
    URL(string: "\(baseURL)/checklists/\(listId)/tasks/\(taskId)/\(action).json")
  }

  // MARK: - Web permalinks

  static func taskPermalink(listId: String, taskId: Int) -> String {
    "\(baseURL)/checklists/\(listId)#t\(taskId)"
  }
}
