import Foundation
import TaktCore
import TaktWorkspace

/// What the pane drew beside an open draft row, taken before a refresh so
/// the row can be kept beside whatever survives it.
struct TaskDraftSurroundings {
  var rows: [TaskDraftRow]
  /// The board column the rows are, when the pane is the board.
  var columnID: String?
}

/// Keeping an open draft row — and what has been typed in it — on screen
/// while the tasks around it change. Split from `WorkspaceViewModel.swift`
/// for size — it is the same type.
///
/// The row is drawn beside its reference task, so a reference that left the
/// pane (a ticked-off task's few seconds running out, a write from the CLI
/// or another device) used to take the row with it, and the half-typed
/// title with that. The title and caret now live here rather than in the
/// row, and a refresh that loses the reference moves the row to the nearest
/// task still drawn (`TaskDraftReanchor`).
@MainActor
extension WorkspaceViewModel {
  /// The rows the draft is drawn among, as the pane draws them now; nil when
  /// no draft is open beside a task, or the pane does not draw one there.
  func taskDraftSurroundings() -> TaskDraftSurroundings? {
    guard isDraftingTask, let reference = taskInsertionReference else { return nil }
    switch viewMode {
    case .outline:
      return TaskDraftSurroundings(
        rows: outlineRows.map { TaskDraftRow(id: $0.id, parentID: $0.task.parentTaskId) })
    case .board:
      guard let column = boardColumns.first(where: { column in
        tasks(in: column).contains { $0.id == reference.id }
      }) else { return nil }
      return TaskDraftSurroundings(rows: tasks(in: column).map { TaskDraftRow(id: $0.id) }, columnID: column.id)
    case .matrix:
      return TaskDraftSurroundings(rows: boardTasks.map { TaskDraftRow(id: $0.id) })
    case .today:
      // Today draws the draft only at the foot of the day.
      return nil
    }
  }

  /// After a refresh: if the reference has left the rows it was drawn
  /// among, draws the draft beside the nearest one left instead. The row's
  /// text, caret and keyboard stay as they were; the selection is not
  /// touched.
  func reanchorTaskDraft(from previous: TaskDraftSurroundings) {
    guard isDraftingTask, let anchor = currentTaskDraftAnchor else { return }
    let current: [WorkspaceTask]
    switch viewMode {
    case .outline: current = outlineRows.map(\.task)
    case .board:
      current = boardColumns.first { $0.id == previous.columnID }.map { tasks(in: $0) } ?? []
    case .matrix: current = boardTasks
    case .today: return
    }
    let rows = viewMode == .outline
      ? current.map { TaskDraftRow(id: $0.id, parentID: $0.parentTaskId) }
      : current.map { TaskDraftRow(id: $0.id) }
    let next = TaskDraftReanchor.anchor(anchor, previous: previous.rows, current: rows)
    guard next != anchor else { return }
    let byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let reference = next.referenceID.flatMap { byID[$0] ?? task(withID: $0) }
    // A board draft with nothing left beside it goes to the foot of the
    // column it was in, not whichever column the selection has moved to.
    if viewMode == .board, let columnID = previous.columnID { taskDraftColumnID = columnID }
    taskInsertionReference = reference
    switch next {
    case .above: taskInsertionAbove = reference != nil; taskInsertionIsChild = false
    case .inside: taskInsertionAbove = false; taskInsertionIsChild = reference != nil
    case .below, .end: taskInsertionAbove = false; taskInsertionIsChild = false
    }
  }

  private var currentTaskDraftAnchor: TaskDraftAnchor? {
    guard let reference = taskInsertionReference else { return nil }
    if taskInsertionIsChild { return .inside(reference.id) }
    return taskInsertionAbove ? .above(reference.id) : .below(reference.id)
  }

  /// The board column a draft with no task beside it is drawn at the foot
  /// of, and files into: the column it was opened in while that is still on
  /// the board, so a selection moved by a task leaving does not carry the
  /// half-typed card to another column.
  var taskDraftBoardColumnID: String? {
    if let id = taskDraftColumnID, boardColumns.contains(where: { $0.id == id }) { return id }
    return activeBoardColumnID
  }

  /// Whether the draft row goes at the foot of `columnID` on the board.
  func draftsAtEnd(ofColumn columnID: String) -> Bool {
    draftsAtEnd && columnID == taskDraftBoardColumnID
  }
}
