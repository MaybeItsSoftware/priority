import Foundation

/// The queue of tasks whose Obsidian folder still needs creating.
///
/// Lifted out of `IntegrationCoordinator`, where these rules were interleaved
/// with `preferencesStore` writes and an `@Observable` property, so none of
/// them could be reached from a test. They are the rules that decide what gets
/// synced and what gets silently dropped.
public enum PendingSyncQueue {

  /// The invariants every stored queue holds: no duplicates, no placeholder
  /// ids, order preserved.
  ///
  /// Non-positive ids are dropped rather than kept, because a task that only
  /// exists optimistically has a negative temp id — queuing one would mean
  /// creating a folder named after an id the server never issues.
  public static func normalized(_ queue: [Int]) -> [Int] {
    var seen = Set<Int>()
    return queue.filter { taskId in
      taskId > 0 && seen.insert(taskId).inserted
    }
  }

  /// Adds a task, or moves it to the back if it is already waiting. Most
  /// recently touched syncs last, so a task edited repeatedly does not starve
  /// the rest of the queue.
  public static func enqueue(_ taskId: Int, into queue: [Int]) -> [Int] {
    normalized(queue.filter { $0 != taskId } + [taskId])
  }

  public static func dequeue(_ taskId: Int, from queue: [Int]) -> [Int] {
    normalized(queue.filter { $0 != taskId })
  }

  /// Drops anything no longer open. A task completed or deleted elsewhere —
  /// on the web, on another machine — would otherwise sit in the queue forever,
  /// since nothing local ever dequeues it.
  public static func reconciled(_ queue: [Int], withOpenTaskIds openTaskIds: Set<Int>) -> [Int] {
    queue.filter { openTaskIds.contains($0) }
  }

  /// The menu bar title prefix. Empty for an empty queue — the menu bar shows
  /// the top task instead, and a "(0)" would be noise.
  public static func menuBarPrefix(count: Int) -> String {
    switch count {
    case ..<1: return ""
    case 1: return "Pending Sync"
    default: return "Pending Sync (\(count))"
    }
  }
}

/// Where a task's external links are filed.
///
/// Keys are scoped by list, so the same task id in two lists — or the same id
/// reused after a list is deleted and recreated — cannot collide.
public enum IntegrationLinkStore {

  /// Tasks created while offline have no list to belong to yet, and share the
  /// `offline` scope until a real list id arrives.
  public static func storageKey(taskId: Int, listId: String) -> String {
    let trimmed = listId.trimmingCharacters(in: .whitespacesAndNewlines)
    return "\(trimmed.isEmpty ? "offline" : trimmed):\(taskId)"
  }

  /// Recorded when a calendar event was created but its URL was not returned,
  /// so "we made one" stays distinguishable from "we never tried".
  public static let createdWithoutURL = "created"

  public static func hasEventLink(
    taskId: Int, listId: String, in links: [String: String]
  ) -> Bool {
    links[storageKey(taskId: taskId, listId: listId)] != nil
  }

  /// `nil` for a task with no link *and* for one recorded without a URL — there
  /// is nothing to open in either case, which is what the caller is asking.
  public static func eventLinkURL(
    taskId: Int, listId: String, in links: [String: String]
  ) -> URL? {
    guard let raw = links[storageKey(taskId: taskId, listId: listId)],
      raw != createdWithoutURL
    else { return nil }
    return URL(string: raw)
  }

  public static func recording(
    eventURL: URL?, taskId: Int, listId: String, into links: [String: String]
  ) -> [String: String] {
    var updated = links
    updated[storageKey(taskId: taskId, listId: listId)] =
      eventURL?.absoluteString ?? createdWithoutURL
    return updated
  }
}
