import Foundation
import TaktCore

/// One rendered line of the task outline: the task, and how far it is indented
/// below the row that revealed it.
///
/// `depth` is *relative to the list*, not to the Checkvist tree — a base row is
/// always depth 0 even when it's a deeply nested task surfaced by the Due or
/// Priority view. Only children revealed by expanding a row indent.
struct TaskOutlineRow: Equatable {
  let task: CheckvistTask
  let depth: Int
}

/// Turns the flat list a view decided to show into a Checkvist-style outline:
/// every expanded row is followed immediately by its children, one level in.
///
/// Kept separate from `TaskVisibilityEngine` on purpose. That engine answers
/// "which tasks does this tab care about", which differs per view and per
/// filter; this one answers "given those, what does the outline look like",
/// which is the same everywhere. Splitting them is also what lets the filtered
/// tabs (Due / Tags / Priority) gain expansion without their sorting and
/// bucketing rules learning about it.
struct TaskOutlineBuilder {
  /// Guards against a malformed parent chain — a cycle would otherwise recurse
  /// until the stack runs out. Deeper than any real Checkvist list.
  static let maximumDepth = 64

  static func flatten(
    base: [CheckvistTask],
    tasks: [CheckvistTask],
    expandedTaskIds: Set<Int>,
    sortChildren: ([CheckvistTask]) -> [CheckvistTask] = { $0 }
  ) -> [TaskOutlineRow] {
    guard !expandedTaskIds.isEmpty else {
      return base.map { TaskOutlineRow(task: $0, depth: 0) }
    }

    var childrenByParentId: [Int: [CheckvistTask]] = [:]
    for task in tasks {
      childrenByParentId[task.parentId ?? 0, default: []].append(task)
    }

    // A filtered tab can list a task *and* one of its ancestors. If that
    // ancestor is expanded the task belongs under it, indented — so work out
    // which base rows get absorbed before emitting any of them, rather than
    // letting the answer depend on which of the two the sort put first.
    let baseIds = Set(base.map(\.id))
    var absorbed = Set<Int>()
    for task in base where expandedTaskIds.contains(task.id) && !absorbed.contains(task.id) {
      var visited: Set<Int> = [task.id]
      collectRevealedDescendants(
        of: task.id,
        childrenByParentId: childrenByParentId,
        expandedTaskIds: expandedTaskIds,
        into: &absorbed,
        limitedTo: baseIds,
        visited: &visited
      )
    }

    var rows: [TaskOutlineRow] = []
    var emitted = Set<Int>()

    func emit(_ task: CheckvistTask, depth: Int) {
      guard !emitted.contains(task.id) else { return }
      emitted.insert(task.id)
      rows.append(TaskOutlineRow(task: task, depth: depth))
      guard expandedTaskIds.contains(task.id), depth < maximumDepth else { return }
      for child in sortChildren(childrenByParentId[task.id] ?? []) {
        emit(child, depth: depth + 1)
      }
    }

    for task in base where !absorbed.contains(task.id) {
      emit(task, depth: 0)
    }
    return rows
  }

  /// Ids that expanding `taskId` will reveal, following the expanded chain
  /// down. `limitedTo` keeps the walk cheap: only base rows can be absorbed, so
  /// there's nothing to learn about the rest of the subtree.
  ///
  /// `visited` starts holding the row the walk began at. A malformed tree that
  /// loops back to it must not absorb it — that would delete the row entirely
  /// rather than move it.
  private static func collectRevealedDescendants(
    of taskId: Int,
    childrenByParentId: [Int: [CheckvistTask]],
    expandedTaskIds: Set<Int>,
    into absorbed: inout Set<Int>,
    limitedTo baseIds: Set<Int>,
    visited: inout Set<Int>,
    depth: Int = 0
  ) {
    guard depth < maximumDepth else { return }
    for child in childrenByParentId[taskId] ?? [] {
      guard visited.insert(child.id).inserted else { continue }
      if baseIds.contains(child.id) {
        absorbed.insert(child.id)
      }
      guard expandedTaskIds.contains(child.id) else { continue }
      collectRevealedDescendants(
        of: child.id,
        childrenByParentId: childrenByParentId,
        expandedTaskIds: expandedTaskIds,
        into: &absorbed,
        limitedTo: baseIds,
        visited: &visited,
        depth: depth + 1
      )
    }
  }
}
