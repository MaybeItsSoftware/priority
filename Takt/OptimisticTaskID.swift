import Foundation

/// Allocates the placeholder ids used for optimistic (not-yet-server-acknowledged)
/// tasks.
///
/// Ids are negative by convention so they can never collide with a real
/// Checkvist id, and they are drawn from a monotonically decreasing sequence
/// rather than picked at random. Randomness was unsafe here for two reasons:
/// temp ids outlive the process (they are persisted in
/// `TaskRepository.pendingTaskCreates` while offline), and every lookup in the
/// task list is an id match — so a repeat silently retargets a different task's
/// replace/remove/rollback.
///
/// The cursor is persisted so ids stay unique across launches while offline
/// creates are still queued.
@MainActor
enum OptimisticTaskID {
  private static let defaultsKey = "nextOptimisticTaskId"

  /// `nil` until the first allocation, which is when the cursor is read back
  /// from whichever store the caller passed. It used to be a `lazy` static
  /// initialised from `UserDefaults.standard` regardless, so an injected store
  /// was written to but never read from — the persistence this type exists to
  /// provide was the one thing its tests could not observe.
  private static var next: Int?

  static func make(defaults: UserDefaults = .standard) -> Int {
    let id = next ?? loadCursor(from: defaults)
    let following = id == Int.min ? -1 : id - 1
    next = following
    defaults.set(following, forKey: defaultsKey)
    return id
  }

  private static func loadCursor(from defaults: UserDefaults) -> Int {
    let stored = defaults.integer(forKey: defaultsKey)
    // `integer(forKey:)` returns 0 when unset; only a previously stored
    // negative cursor is meaningful.
    return stored < 0 ? stored : -1
  }

  /// Drops the in-memory cursor so the next `make` re-reads from its store.
  /// Only for tests, which need each case to start from a known state.
  static func resetForTesting() {
    next = nil
  }
}
