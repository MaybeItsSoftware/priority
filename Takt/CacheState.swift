import Foundation
import TaktCore

/// Holds the pre-computed caches that drive visible-task filtering,
/// tag lookups and due-date bucketing.
///
/// Owned by `TaskListViewModel`; rebuilt when the dirty flag is set.
struct CacheState {
  /// Dirty flag set by `invalidateCaches()`; cleared after recomputation.
  var dirty = true
  /// Prevents recursive cache rebuilds when visibility sorting reads cached helpers.
  var isRebuilding = false

  var visibleTasks: [CheckvistTask] = []
  /// Task id → rank within the task's own parent scope (1-based).
  var priorityRank: [Int: Int] = [:]
  /// Task id → absolute priority rank across the entire list (1-based).
  var absolutePriorityRank: [Int: Int] = [:]
  var taskById: [Int: CheckvistTask] = [:]
  /// Pre-extracted lowercased tags per task ID, built once during cache rebuild.
  var tagsByTaskId: [Int: [String]] = [:]
  /// Pre-computed due bucket per task ID, avoiding repeated date math in filters/sorts.
  var rootDueBucket: [Int: RootDueBucket] = [:]

  mutating func invalidate() {
    dirty = true
  }
}
