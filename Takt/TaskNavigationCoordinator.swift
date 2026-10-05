import Foundation

struct TaskNavigationSelection {
  let rootScopeFocusLevel: Int
  let currentParentId: Int
  let currentSiblingIndex: Int
}

/// What pressing right or left on an outline row should do. Resolved from the
/// rows alone so the decision can be unit-tested; `TaskNavigationService`
/// applies it.
enum OutlineNavigationOutcome: Equatable {
  case expand(taskId: Int)
  case collapse(taskId: Int)
  case select(index: Int)
  /// Left on a top-level, collapsed row — pop out of the current scope, which
  /// is what left has always done.
  case exitScope
  case none
}

struct TaskNavigationCoordinator {
  func nextSiblingIndex(currentSiblingIndex: Int, visibleCount: Int) -> Int? {
    guard visibleCount > 0 else { return nil }
    let clampedIndex = min(max(currentSiblingIndex, 0), visibleCount - 1)
    return (clampedIndex + 1) % visibleCount
  }

  func previousSiblingIndex(currentSiblingIndex: Int, visibleCount: Int) -> Int? {
    guard visibleCount > 0 else { return nil }
    let clampedIndex = min(max(currentSiblingIndex, 0), visibleCount - 1)
    return (clampedIndex - 1 + visibleCount) % visibleCount
  }

  func enterChildren(currentTask: CheckvistTask?, childCount: Int) -> TaskNavigationSelection? {
    guard let currentTask, childCount > 0 else { return nil }
    return TaskNavigationSelection(
      rootScopeFocusLevel: 0, currentParentId: currentTask.id, currentSiblingIndex: 0)
  }

  func exitToParent(currentParentId: Int, tasks: [CheckvistTask]) -> TaskNavigationSelection? {
    guard currentParentId != 0 else { return nil }

    guard let parent = tasks.first(where: { $0.id == currentParentId }) else {
      return TaskNavigationSelection(
        rootScopeFocusLevel: 0, currentParentId: 0, currentSiblingIndex: 0)
    }

    let grandparentId = parent.parentId ?? 0
    let siblings = tasks.filter { ($0.parentId ?? 0) == grandparentId }
    let siblingIndex = siblings.firstIndex(where: { $0.id == parent.id }) ?? 0
    return TaskNavigationSelection(
      rootScopeFocusLevel: 0,
      currentParentId: grandparentId,
      currentSiblingIndex: siblingIndex
    )
  }

  // MARK: - Outline movement

  /// Right: open the selected row if it has children and is shut, otherwise
  /// step into the children it is already showing.
  func expandOrDescend(
    selectedIndex: Int,
    rows: [TaskOutlineRow],
    expandedTaskIds: Set<Int>,
    childCountByTaskId: [Int: Int]
  ) -> OutlineNavigationOutcome {
    guard rows.indices.contains(selectedIndex) else { return .none }
    let row = rows[selectedIndex]
    guard childCountByTaskId[row.task.id, default: 0] > 0 else { return .none }
    guard expandedTaskIds.contains(row.task.id) else { return .expand(taskId: row.task.id) }
    let childIndex = selectedIndex + 1
    guard rows.indices.contains(childIndex), rows[childIndex].depth == row.depth + 1 else {
      // Expanded but showing nothing: the children are filtered out of this
      // tab. Leave the cursor where it is rather than jumping somewhere
      // arbitrary.
      return .none
    }
    return .select(index: childIndex)
  }

  /// Left: shut the selected row if it's open, else go up to the parent row
  /// showing it, else leave the scope entirely.
  func collapseOrAscend(
    selectedIndex: Int,
    rows: [TaskOutlineRow],
    expandedTaskIds: Set<Int>,
    childCountByTaskId: [Int: Int]
  ) -> OutlineNavigationOutcome {
    guard rows.indices.contains(selectedIndex) else { return .exitScope }
    let row = rows[selectedIndex]
    if expandedTaskIds.contains(row.task.id), childCountByTaskId[row.task.id, default: 0] > 0 {
      return .collapse(taskId: row.task.id)
    }
    guard row.depth > 0 else { return .exitScope }
    guard let parentIndex = (0..<selectedIndex).reversed().first(where: { rows[$0].depth < row.depth })
    else { return .exitScope }
    return .select(index: parentIndex)
  }

  func navigate(to task: CheckvistTask, tasks: [CheckvistTask]) -> TaskNavigationSelection {
    let parentId = task.parentId ?? 0
    let siblings = tasks.filter { ($0.parentId ?? 0) == parentId }
    let siblingIndex = siblings.firstIndex(where: { $0.id == task.id }) ?? 0
    return TaskNavigationSelection(
      rootScopeFocusLevel: 0,
      currentParentId: parentId,
      currentSiblingIndex: siblingIndex
    )
  }
}
