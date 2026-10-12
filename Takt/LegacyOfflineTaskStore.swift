import Foundation
import OSLog

/// What the old offline store left in the preferences: the tasks of the
/// Checkvist-era offline workspace, in Checkvist's shape.
struct OfflineTaskStorePayload: Codable {
  let openTasks: [CheckvistTask]
  let archivedTasks: [CheckvistTask]
  let nextTaskId: Int

  static let empty = OfflineTaskStorePayload(openTasks: [], archivedTasks: [], nextTaskId: 1)
}

/// Reads the old offline store, once, for `WorkspaceViewModel`'s migration of
/// it into the workspace. Nothing writes it any more: the offline sync plugin
/// that kept it went with the rest of the Checkvist-era task stack.
final class LegacyOfflineTaskStore {
  private let defaults: UserDefaults
  private let payloadKey = "offlineTaskStorePayload"
  private let logger = Logger(
    subsystem: "uk.co.maybeitssoftware.takt", category: "legacy-offline-store")

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func load() -> OfflineTaskStorePayload {
    guard let data = defaults.data(forKey: payloadKey) else { return .empty }
    do {
      return try JSONDecoder().decode(OfflineTaskStorePayload.self, from: data)
    } catch {
      logger.error(
        "Failed to decode the old offline task store: \(error.localizedDescription, privacy: .public)")
      return .empty
    }
  }
}
