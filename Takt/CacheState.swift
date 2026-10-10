import Foundation
import TaktCore

/// Holds the pre-computed caches that drive visible-task filtering,
/// tag lookups, due-date bucketing, and timer roll-ups.
///
/// Owned by `AppCoordinator`; rebuilt when the dirty flag is set.
struct CacheState {
  /// Dirty flag set by `invalidateCaches()`; cleared after recomputation.
  var dirty = true
  /// Prevents recursive cache rebuilds when visibility sorting reads cached helpers.
  var isRebuilding = false

  var visibleTasks: [CheckvistTask] = []
  /// Indent level per entry of `visibleTasks`, parallel to it. 0 for the rows
  /// the view chose; deeper for children revealed by expanding one of them.
  var outlineDepths: [Int] = []
  /// Index in `visibleTasks` at which the "Remainder" section begins, or nil when
  /// the current view does not split matching / non-matching tasks. Used by
  /// due/tags/priority root views to render a header and keep the full task list
  /// reachable even when the filter would otherwise produce an empty state.
  var remainderStartIndex: Int?
  var childCount: [Int: Int] = [:]
  var rolledUpElapsed: [Int: TimeInterval] = [:]
  /// Task id → rank within the task's own parent scope (1-based).
  var priorityRank: [Int: Int] = [:]
  /// Task id → absolute priority rank across the entire list (1-based).
  var absolutePriorityRank: [Int: Int] = [:]
  /// Task id → hierarchical priority path (e.g. "1.2.=.3"). Only populated for tasks
  /// that are themselves ranked. Uses "=" for unranked ancestors.
  var priorityPath: [Int: String] = [:]
  var rootLevelTagNames: [String] = []
  var taskById: [Int: CheckvistTask] = [:]
  /// Pre-extracted lowercased tags per task ID, built once during cache rebuild.
  var tagsByTaskId: [Int: [String]] = [:]
  /// Pre-computed due bucket per task ID, avoiding repeated date math in filters/sorts.
  var rootDueBucket: [Int: RootDueBucket] = [:]

  mutating func invalidate() {
    dirty = true
  }
}
