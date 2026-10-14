import Foundation
import TaktCore
import TaktWorkspace

/// One row of Today as it is drawn: a task of the day, or an open subtask
/// shown beneath one you have unfolded.
struct DayTreeItem: Identifiable, Equatable {
  let task: WorkspaceTask
  /// What put it on the day; nil for a subtask that is only here because its
  /// parent is, and for the fallback ranking.
  let reason: DayPlanReason?
  let row: DayOutlineRow

  var id: String { task.id }
}

/// Opening a task in Today to work its subtasks where they stand, as
/// Checkvist unfolds a branch: → shows them and steps in, ← folds them and
/// steps back out. Which rows are drawn is `DayOutline`'s; this reads the
/// subtasks and keeps the fold.
@MainActor
extension WorkspaceViewModel {
  static let todayUnfoldedTasksKey = "localWorkspaceTodayUnfoldedTasksV1"

  /// Rebuilds `dayTree` from `dayItems` and the folds.
  func rebuildDayTree() {
    var tasks = Dictionary(dayItems.map { ($0.id, $0.task) }, uniquingKeysWith: { first, _ in first })
    let reasons = Dictionary(dayItems.map { ($0.id, $0.reason) }, uniquingKeysWith: { first, _ in first })
    let rows = DayOutline.rows(day: dayItems.map(\.id), unfolded: todayUnfoldedTaskIDs) { id in
      guard let task = tasks[id] else { return [] }
      let children = dayChildren(of: task)
      for child in children where tasks[child.id] == nil { tasks[child.id] = child }
      return children.map(\.id)
    }
    let tree = rows.compactMap { row in
      tasks[row.id].map { DayTreeItem(task: $0, reason: reasons[row.id] ?? nil, row: row) }
    }
    if dayTree != tree { dayTree = tree }
  }

  /// A task's open subtasks, in outline order. Lists inside it are left out:
  /// the day is for things to do, and a list is somewhere to go.
  private func dayChildren(of task: WorkspaceTask) -> [WorkspaceTask] {
    if let cached = dayChildrenCache[task.id] { return cached }
    let children = ((try? store?.tasks(in: task.listId, parentTaskId: task.id)) ?? [])
      .filter { $0.status == .open && !$0.isList }
    dayChildrenCache[task.id] = children
    // Resolvable by id at once, so the inspector and the task keys on a
    // subtask row do not each go back to the store for it.
    for child in children where taskCache[child.id] == nil { taskCache[child.id] = child }
    return children
  }

  func isDayTaskUnfolded(_ id: String) -> Bool {
    todayUnfoldedTaskIDs.contains(id)
  }

  /// Opens or folds a row's subtasks. Folding away the row the cursor was
  /// on leaves it on the row folded.
  func setDayTaskUnfolded(_ id: String, _ unfolded: Bool) {
    if unfolded {
      todayUnfoldedTaskIDs.insert(id)
      return
    }
    let rows = dayTree.map(\.row)
    let cursorInside = selectedTaskID.map { DayOutline.isDrawn($0, beneath: id, in: rows) } ?? false
    todayUnfoldedTaskIDs.remove(id)
    if cursorInside { selectedTaskID = id }
  }

  func toggleDayFold(_ id: String) {
    WorkspaceMotion.animate { setDayTaskUnfolded(id, !isDayTaskUnfolded(id)) }
  }

  /// → and `l` on Today: open a folded task, then step into it. A row with
  /// nothing beneath it carries on to the inspector, as in the outline.
  func unfoldOrDescendDaySelection() {
    guard let id = selectedTaskID, dayTree.contains(where: { $0.id == id }) else {
      selectedTaskID = dayTree.first?.id
      return
    }
    switch DayOutline.right(from: id, in: dayTree.map(\.row)) {
    case .unfold(let id): WorkspaceMotion.animate { setDayTaskUnfolded(id, true) }
    case .select(let child): selectedTaskID = child
    case .fold, .leave: requestKeyboardFocus(.inspector)
    }
  }

  /// ← and `h` on Today: fold an open task, then step up to the task a
  /// subtask hangs from, and from the top of the day back to the sidebar.
  func foldOrAscendDaySelection() {
    guard let id = selectedTaskID, dayTree.contains(where: { $0.id == id }) else {
      returnToCurrentListInSidebar()
      return
    }
    switch DayOutline.left(from: id, in: dayTree.map(\.row)) {
    case .fold(let id): WorkspaceMotion.animate { setDayTaskUnfolded(id, false) }
    case .select(let parent): selectedTaskID = parent
    case .unfold, .leave: returnToCurrentListInSidebar()
    }
  }

  /// The task a subtask row is drawn beneath on Today, for adding beside it.
  /// Nil for a task of the day itself.
  func dayTreeParentID(of id: String) -> String? {
    dayTree.first { $0.id == id }?.row.parentID
  }
}
