import Foundation

/// Batches reorder requests and drains them sequentially against the remote API.
///
/// Owned by `AppCoordinator`. Callers enqueue position changes; the queue
/// coalesces per-task-id and flushes in order, retrying on failure via a
/// delayed resync.
@MainActor
final class ReorderQueue {
  struct Request {
    let taskId: Int
    let position: Int
  }

  private(set) var pending: [Request] = []
  private var syncTask: Task<Void, Never>?
  private var resyncTask: Task<Void, Never>?

  var isSyncing: Bool { syncTask != nil }

  func enqueue(taskId: Int, position: Int) {
    pending.removeAll { $0.taskId == taskId }
    pending.append(Request(taskId: taskId, position: position))
  }

  func dequeueNext() -> Request? {
    guard !pending.isEmpty else { return nil }
    return pending.removeFirst()
  }

  func setSyncTask(_ task: Task<Void, Never>?) {
    syncTask = task
  }

  func setResyncTask(_ task: Task<Void, Never>?) {
    resyncTask?.cancel()
    resyncTask = task
  }

  func cancelAll() {
    syncTask?.cancel()
    syncTask = nil
    resyncTask?.cancel()
    resyncTask = nil
    pending.removeAll()
  }
}
