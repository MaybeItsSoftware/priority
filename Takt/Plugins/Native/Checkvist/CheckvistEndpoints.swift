import Foundation

/// Where Checkvist is, and what the Mac calls itself there. The API's paths
/// are the core's (`core/src/checkvist.rs`), which makes every request.
/// Change `baseURL` once to point at a self-hosted or staging instance.
enum CheckvistEndpoints {
  static let baseURL = "https://checkvist.com"

  /// Sent on every request so Checkvist's logs can tell this client apart.
  static let userAgent = "Takt/1.0 (Macintosh; Mac OS X)"

  // MARK: - Web permalinks

  static func taskPermalink(listId: String, taskId: Int) -> String {
    "\(baseURL)/checklists/\(listId)#t\(taskId)"
  }
}
