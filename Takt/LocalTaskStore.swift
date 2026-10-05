import Foundation
import OSLog

struct OfflineTaskStorePayload: Codable {
  let openTasks: [CheckvistTask]
  let archivedTasks: [CheckvistTask]
  let nextTaskId: Int

  static let empty = OfflineTaskStorePayload(openTasks: [], archivedTasks: [], nextTaskId: 1)
}

final class LocalTaskStore {
  private let defaults: UserDefaults
  private let payloadKey = "offlineTaskStorePayload"
  private let logger = Logger(
    subsystem: "uk.co.maybeitssoftware.takt", category: "local-task-store")

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func load() -> OfflineTaskStorePayload {
    guard let data = defaults.data(forKey: payloadKey) else { return .empty }
    do {
      return try JSONDecoder().decode(OfflineTaskStorePayload.self, from: data)
    } catch {
      logger.error(
        "Failed to decode offline task store: \(error.localizedDescription, privacy: .public)")
      return .empty
    }
  }

  func save(_ payload: OfflineTaskStorePayload) {
    do {
      let data = try JSONEncoder().encode(payload)
      defaults.set(data, forKey: payloadKey)
    } catch {
      logger.error(
        "Failed to encode offline task store: \(error.localizedDescription, privacy: .public)")
    }
  }
}

/// On-disk representation of `TaskRepository`'s four pending-offline queues.
/// `listId` scopes the payload — a payload for a different list is discarded
/// at load time, which is the conservative choice given that a mutation
/// targeting list A would do the wrong thing if replayed against list B.
struct PendingOfflineWorkPayload: Codable {
  let listId: String
  let creates: [PendingTaskCreate]
  let actions: [PendingTaskAction]
  let deletes: [Int]
  let mutations: [Int: PendingTaskUpdate]

  static let empty = PendingOfflineWorkPayload(
    listId: "", creates: [], actions: [], deletes: [], mutations: [:])

  var isEmpty: Bool {
    creates.isEmpty && actions.isEmpty && deletes.isEmpty && mutations.isEmpty
  }
}

/// Durable persistence for offline-queued task work so that creates,
/// completions, deletes, and updates made while the network is unreachable
/// survive an app relaunch and still flush on the next reconnect.
final class PendingOfflineWorkStore {
  private let defaults: UserDefaults
  private let payloadKey = "pendingOfflineWorkPayload"
  private let logger = Logger(
    subsystem: "uk.co.maybeitssoftware.takt", category: "pending-offline-work")

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func load() -> PendingOfflineWorkPayload {
    guard let data = defaults.data(forKey: payloadKey) else { return .empty }
    do {
      return try JSONDecoder().decode(PendingOfflineWorkPayload.self, from: data)
    } catch {
      logger.error(
        "Failed to decode pending offline work: \(error.localizedDescription, privacy: .public)")
      return .empty
    }
  }

  func save(_ payload: PendingOfflineWorkPayload) {
    if payload.isEmpty {
      defaults.removeObject(forKey: payloadKey)
      return
    }
    do {
      let data = try JSONEncoder().encode(payload)
      defaults.set(data, forKey: payloadKey)
    } catch {
      logger.error(
        "Failed to encode pending offline work: \(error.localizedDescription, privacy: .public)")
    }
  }

  func clear() {
    defaults.removeObject(forKey: payloadKey)
  }
}
