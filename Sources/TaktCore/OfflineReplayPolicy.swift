import Foundation

/// What to do with a single piece of offline-queued work (a delete, a
/// close/reopen action, or a content/due update) when the queue is replayed.
public enum OfflineReplayResolution: Equatable, Sendable {
  /// Send it to the server against this id.
  case send(taskId: Int)
  /// The task it targets still has an unfulfilled create ahead of it. Put the
  /// work back on the queue against the *temp* id so the next flush retries it.
  case requeue(tempId: Int)
  /// The create it depended on is gone for good, so the work is moot.
  case drop
}

/// Decides how queued offline work maps onto server ids once the creates ahead
/// of it have been replayed.
///
/// Split out of `SyncService.flushPendingTaskMutations` because the ordering
/// rule here is subtle and was previously wrong: a create that failed and got
/// re-queued was indistinguishable from a create that had vanished, so the
/// dependent delete/close/update was silently dropped. The create then
/// succeeded on the next flush and the task the user had completed or deleted
/// while offline came back — permanently.
public enum OfflineReplayPolicy {
  /// - Parameters:
  ///   - taskId: The id recorded on the queued work. Negative means it refers
  ///     to a not-yet-created task via its optimistic placeholder id.
  ///   - tempIdToRealId: Placeholder → server id, for creates that succeeded
  ///     during this flush.
  ///   - requeuedCreateTempIds: Placeholders whose create failed during this
  ///     flush and has been put back on the queue.
  public static func resolve(
    taskId: Int,
    tempIdToRealId: [Int: Int],
    requeuedCreateTempIds: Set<Int>
  ) -> OfflineReplayResolution {
    // Real server ids need no mapping.
    guard taskId < 0 else { return .send(taskId: taskId) }

    // Checked before the success map: a create can only be in one of the two,
    // but ordering it this way keeps the intent explicit.
    if requeuedCreateTempIds.contains(taskId) {
      return .requeue(tempId: taskId)
    }
    if let realId = tempIdToRealId[taskId] {
      return .send(taskId: realId)
    }
    return .drop
  }
}
