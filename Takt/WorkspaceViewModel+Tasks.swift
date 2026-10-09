import Foundation
import TaktCore
import TaktWorkspace

/// Creating, placing and classifying tasks: the outline's own writes, the
/// board's columns, and the matrix's coordinates. Split from
/// `WorkspaceViewModel.swift` for size — it is the same type, and these are
/// the methods a view calls when it wants a task to exist or to move.
@MainActor
extension WorkspaceViewModel {
  func createTask(named title: String) {
    if taskInsertionReference != nil { createRelativeTask(named: title); return }
    guard let store,
      let destinationID = isMultiListScope ? (folderScopeDestinationID ?? newTaskListID) : selectedListID,
      let destinationList = lists.first(where: { $0.id == destinationID })
    else { return }
    perform {
      let parentID = isMultiListScope
        ? try visibleRootParentTaskID(for: destinationList, store: store) : scopeTaskID
      let task = try store.createTask(capturing: title, listId: destinationID, parentTaskId: parentID)
      selectedTaskID = task.id
      reloadOutline()
    }
  }

  private func createRelativeTask(named title: String) {
    guard let store, let reference = taskInsertionReference else { return }
    perform {
      let task = try store.createTask(capturing: title, listId: reference.listId,
        parentTaskId: taskInsertionIsChild ? reference.id : reference.parentTaskId,
        kanbanColumn: viewMode == .board ? column(for: reference)?.id : nil,
        adjacentTaskId: taskInsertionIsChild ? nil : reference.id, above: taskInsertionAbove)
      if taskInsertionIsChild { scopeTaskID = reference.id }
      selectedTaskID = task.id
      taskInsertionReference = task
      taskInsertionAbove = false
      taskInsertionIsChild = false
      reloadOutline()
    }
  }

  /// Creates work in the currently visible board scope. This differs from the
  /// outline only for a transparent imported root project (see
  /// `boardParentTaskID`), where a new card belongs alongside the visible
  /// children rather than appearing above them as a second wrapper.
  @discardableResult
  func createBoardTask(named title: String, in column: WorkspaceKanbanColumn? = nil)
    -> WorkspaceTask?
  {
    if column == nil && taskInsertionReference != nil { createRelativeTask(named: title); return nil }
    guard let store,
      let destinationID = isMultiListScope ? (folderScopeDestinationID ?? newTaskListID) : selectedListID,
      let destinationList = lists.first(where: { $0.id == destinationID })
    else { return nil }
    var created: WorkspaceTask?
    // A draft files into the column it is drawn at the foot of.
    let columnID = isDraftingTask ? taskDraftBoardColumnID : activeBoardColumnID
    let column = column ?? boardColumns.first { $0.id == columnID }
    perform {
      let parentID = isMultiListScope
        ? try visibleRootParentTaskID(for: destinationList, store: store) : boardParentTaskID
      let task = try store.createTask(capturing: title, listId: destinationID, parentTaskId: parentID,
        kanbanColumn: column?.id, defaultDueAt: addedTodayDueAt)
      created = task
      selectedTaskID = task.id
      reloadOutline()
    }
    return created
  }

  func descendants(of task: WorkspaceTask) -> [TaskOutlineItem] {
    // A board card's descendants are observed directly — a subtask surfaced
    // as a card of its own included, see `WorkspaceBoardTrees` — so the board
    // never reaches the store from a view body. Only the fallback below, for
    // a task off the board, needs to hear that the rows it read were replaced.
    if let cached = boardDescendants[task.id] { return cached }
    _ = taskContentRevision
    if let cached = descendantCache[task.id] { return cached }
    guard let store else { return [] }
    let items = (try? store.outline(in: task.listId, parentTaskId: task.id)) ?? []
    descendantCache[task.id] = items
    return items
  }

  func boardParent(of task: WorkspaceTask) -> WorkspaceTask? {
    boardTaskParents[task.id].flatMap { self.task(withID: $0) }
  }

  var currentBoardScopeTitle: String {
    if isEverythingSelected { return "Everything" }
    if let folder = scopedFolder { return folder.name }
    return scopeTask?.title ?? selectedList?.name ?? "Board"
  }

  /// Where leaving the opened task goes: its parent task, or the list it sits
  /// in. The breadcrumb used to print the opened task's own title, which is
  /// already the pane's title beside it.
  var scopeExitTitle: String? {
    guard let scope = scopeTask else { return nil }
    if let parentID = scope.parentTaskId, let parent = task(withID: parentID) { return parent.title }
    return list(for: scope)?.name ?? selectedList?.name
  }

  func tasks(in column: WorkspaceKanbanColumn) -> [WorkspaceTask] {
    boardTasksByColumn[column.id, default: []]
  }

  /// The subtask rows a card is drawing: none while it is folded, none
  /// beneath a folded subtask, and at most the tree's row limit — the rows
  /// past it are behind "+N more".
  func boardTreeRows(of card: WorkspaceTask) -> [TaskOutlineItem] {
    Array(boardTreeUnfoldedRows(of: card).prefix(WorkspaceBoardMetrics.visibleSubtaskRows))
  }

  /// Every subtask row the card's folds leave showing, before the row limit.
  func boardTreeUnfoldedRows(of card: WorkspaceTask) -> [TaskOutlineItem] {
    guard !foldedTaskIDs.contains(card.id) else { return [] }
    return TaskOutlineFolding.visible(descendants(of: card), folded: foldedTaskIDs)
  }

  /// Every row the arrow keys stop on in a column, top to bottom: each card,
  /// then the subtask rows drawn on it.
  func boardRowIDs(in column: WorkspaceKanbanColumn) -> [String] {
    boardRows(in: column).ids
  }

  /// A column's rows and the card each is drawn on, from the index
  /// `rebuildBoardRowIndex()` keeps.
  func boardRows(in column: WorkspaceKanbanColumn) -> BoardColumnRows {
    boardRowsByColumn[column.id] ?? .empty
  }

  /// Flattens every card's drawn tree once, so an arrow key looks rows up
  /// rather than walking each card's subtasks. Run whenever the board is read
  /// and whenever a fold changes, the only two things the rows turn on.
  func rebuildBoardRowIndex() {
    var index: [String: BoardColumnRows] = [:]
    for column in boardColumns {
      index[column.id] = BoardColumnRows(cards: tasks(in: column).map { card in
        (id: card.id, rowIDs: boardTreeRows(of: card).map(\.task.id))
      })
    }
    if boardRowsByColumn != index { boardRowsByColumn = index }
  }

  /// The card a row is drawn on: the row itself when it is a card, else the
  /// nearest ancestor that is one.
  func boardCardID(owning rowID: String) -> String? {
    var id = rowID
    while !boardVisibleTaskIDs.contains(id) {
      guard let parent = boardTaskParents[id] else { return nil }
      id = parent
    }
    return id
  }

  // MARK: - Folding

  func isFolded(_ task: WorkspaceTask) -> Bool {
    foldedTaskIDs.contains(task.id)
  }

  /// Folds or unfolds a task's subtasks where they are drawn — beneath it in
  /// the outline, or on the card or row it is on the board. Folding away the
  /// row the selection was on leaves it on the task.
  func setFolded(_ task: WorkspaceTask, _ folded: Bool) {
    guard folded else { foldedTaskIDs.remove(task.id); return }
    foldedTaskIDs.insert(task.id)
    if let selectedTaskID, selectedTaskID != task.id,
      descendants(of: task).contains(where: { $0.task.id == selectedTaskID }) {
      self.selectedTaskID = task.id
    }
  }

  /// Opens every folded branch a task sits in, so going to it — from search,
  /// or the done rail — lands on a row that is drawn.
  func unfoldAncestors(of task: WorkspaceTask) {
    var parentID = task.parentTaskId
    var visited = Set<String>()
    while let id = parentID, visited.insert(id).inserted {
      foldedTaskIDs.remove(id)
      parentID = self.task(withID: id)?.parentTaskId
    }
  }

  func toggleFold(of task: WorkspaceTask) {
    WorkspaceMotion.animate { setFolded(task, !isFolded(task)) }
  }

  /// `.`: shows the selected task's subtasks.
  func growSelectedTask() {
    guard let task = selectedTask, isFolded(task) else { return }
    WorkspaceMotion.animate { setFolded(task, false) }
  }

  /// `,`: hides the selected task's subtasks, or — on a task with none, or
  /// already folded — the subtasks of the task it sits under, which takes
  /// the selection with it.
  func shrinkSelectedTask() {
    guard let task = selectedTask else { return }
    if !isFolded(task) && !descendants(of: task).isEmpty {
      WorkspaceMotion.animate { setFolded(task, true) }
    } else if let parent = drawnParent(of: task) {
      WorkspaceMotion.animate { setFolded(parent, true) }
    }
  }

  /// The task a row is drawn beneath on screen: on the board, the card or row
  /// it hangs from; in the outline, a row above it — never the list's hidden
  /// root or the task the pane has opened, whose fold would empty the pane.
  private func drawnParent(of task: WorkspaceTask) -> WorkspaceTask? {
    if viewMode == .board { return boardParent(of: task) }
    guard let parentID = TaskOutlineFolding.parentID(of: task.id, in: outlineRows) else { return nil }
    return self.task(withID: parentID)
  }

  /// Folds or unfolds every branch of the outline on screen. Folding leaves
  /// the selection on the top-level task it was inside.
  func setOutlineFolded(_ folded: Bool) {
    if folded {
      foldedTaskIDs.formUnion(outlineParentIDs)
      var id = selectedTaskID
      while let current = id, !outlineRows.contains(where: { $0.id == current }) {
        id = TaskOutlineFolding.parentID(of: current, in: outline)
      }
      if selectedTaskID != nil, let id { selectedTaskID = id }
    } else {
      foldedTaskIDs.subtract(outlineParentIDs)
    }
  }

  /// → on the outline, as in Checkvist: open a folded branch, then step into
  /// it. A task with nothing beneath it stays put — Return opens it.
  func unfoldOrDescendSelection() {
    guard let task = selectedTask else {
      selectedTaskID = outlineRows.first?.id
      return
    }
    // A task with nothing under it has nowhere further right to go in the
    // outline, so → carries on to the inspector beside it — the details are
    // the next thing to the right.
    guard outlineParentIDs.contains(task.id) else {
      requestKeyboardFocus(.inspector)
      return
    }
    if isFolded(task) {
      WorkspaceMotion.animate { setFolded(task, false) }
    } else if let child = TaskOutlineFolding.firstChildID(of: task.id, in: outlineRows) {
      selectedTaskID = child
    }
  }

  /// ← on the outline: fold an open branch, then step up to the task it hangs
  /// from, and at the top of the outline leave, the way ← always has.
  func foldOrAscendSelection() {
    guard let task = selectedTask, outlineRows.contains(where: { $0.id == task.id }) else {
      leaveSelectedTaskScope()
      return
    }
    if outlineParentIDs.contains(task.id) && !isFolded(task) {
      WorkspaceMotion.animate { setFolded(task, true) }
    } else if let parent = TaskOutlineFolding.parentID(of: task.id, in: outlineRows) {
      selectedTaskID = parent
    } else {
      leaveSelectedTaskScope()
    }
  }

  var todayTasks: [WorkspaceTask] {
    guard let today = boardColumns.first(where: { $0.id == "today" }) else { return [] }
    return tasks(in: today).filter { $0.status == .open }
  }

  func isTaskVisibleOnBoard(_ task: WorkspaceTask) -> Bool {
    boardVisibleTaskIDs.contains(task.id)
  }

  func column(for task: WorkspaceTask) -> WorkspaceKanbanColumn? {
    let id = boardTaskColumns[task.id] ?? WorkspaceKanbanColumn.blitzitDefaults[0].id
    return boardColumnsByID[id] ?? boardColumns.first
  }

  /// The column a task is filed in, whether or not it is on the board: a
  /// task off it, or every task while the board is set aside, is read on its
  /// own and kept until the next refresh.
  func kanbanColumnID(ofTaskID id: String) -> String? {
    if let column = boardTaskColumns[id] { return column }
    let revision = taskContentRevision
    if offBoardColumnCache.revision != revision { offBoardColumnCache = (revision, [:]) }
    if let cached = offBoardColumnCache.columns[id] { return cached }
    let column = store.flatMap { try? $0.boardMetadata(for: [id]).columns[id] }
    offBoardColumnCache.columns[id] = .some(column)
    return column
  }

  /// Assigns only what changed: every card and column reads these, and an
  /// assignment is a redraw whether or not the value moved.
  func rebuildBoardIndex() {
    let byID = Dictionary(boardColumns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    if boardColumnsByID != byID { boardColumnsByID = byID }
    let tasks = boardTasks + boardCrossColumnTasks
    let visible = Set(tasks.map(\.id))
    if boardVisibleTaskIDs != visible { boardVisibleTaskIDs = visible }
    let grouped = Dictionary(grouping: tasks) { task in
      column(for: task)?.id ?? ""
    }
    if boardTasksByColumn != grouped { boardTasksByColumn = grouped }
    let quadrants = MatrixQuadrantIndex(boardTasks) { task in
      let position = matrixPosition(for: task)
      return (position.urgency, position.importance)
    }
    if matrixQuadrants != quadrants { matrixQuadrants = quadrants }
    rebuildBoardRowIndex()
  }

  /// The column a visible card sits in, by id alone — so the board can ask
  /// where the selection is without resolving the selected task.
  func boardColumnID(forTaskID id: String) -> String? {
    guard boardVisibleTaskIDs.contains(id) else { return nil }
    let columnID = boardTaskColumns[id] ?? WorkspaceKanbanColumn.blitzitDefaults[0].id
    return (boardColumnsByID[columnID] ?? boardColumns.first)?.id
  }

  func moveTask(_ task: WorkspaceTask, toKanbanColumn column: WorkspaceKanbanColumn) {
    guard let store else { return }
    perform {
      try store.setKanbanColumn(column.id, for: task.id)
      reloadBoard()
    }
  }

  func placeTask(_ task: WorkspaceTask, before target: WorkspaceTask) {
    guard let store, task.id != target.id else { return }
    guard task.listId == target.listId, task.parentTaskId == target.parentTaskId else {
      errorMessage = "To reorder these cards, they must be siblings in the same project. Drag to a column or list to move them."
      return
    }
    perform {
      try store.moveTaskBefore(id: task.id, targetId: target.id, kanbanColumn: column(for: target)?.id)
      reloadBoard()
    }
  }

  func addKanbanColumn(named name: String) {
    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    guard let store else { return }
    var columns = boardColumns
    let baseID = title.lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let id = uniqueColumnID(base: baseID.isEmpty ? "column" : baseID, in: columns)
    columns.append(WorkspaceKanbanColumn(id: id, title: title))
    perform {
      try store.setKanbanBoardColumns(columns, for: boardConfigurationKey, label: "Add Board Column")
      reloadOutline()
    }
  }

  func removeKanbanColumn(_ column: WorkspaceKanbanColumn) {
    guard boardColumns.count > 1 else { return }
    let fallback = boardColumns.first { $0.id != column.id } ?? WorkspaceKanbanColumn.blitzitDefaults[0]
    guard let store else { return }
    let remaining = boardColumns.filter { $0.id != column.id }
    perform {
      try store.setKanbanBoardColumns(remaining, for: boardConfigurationKey,
        movingTaskIDs: tasks(in: column).map(\.id), toColumn: fallback.id, label: "Remove Board Column")
      reloadOutline()
    }
  }

  func matrixPosition(for task: WorkspaceTask) -> TaskMatrixPosition {
    matrixPositions[task.id] ?? TaskMatrixPosition(urgency: nil, importance: nil)
  }

  func setMatrixPosition(_ position: TaskMatrixPosition, for task: WorkspaceTask) {
    guard let store else { return }
    perform {
      try store.setMatrixPosition(position, for: task.id)
      reloadBoard()
    }
  }
}
