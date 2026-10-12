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
    // A sibling of a subtask row is drawn on the same card: filed where the
    // row is filed, which for most rows is nowhere — they follow the card.
    let boardColumn = boardDraftIsSubtaskRow ? boardTaskColumns[reference.id] : column(for: reference)?.id
    perform {
      var parentID = taskInsertionIsChild ? reference.id : reference.parentTaskId
      var adjacentID = taskInsertionIsChild ? nil : reference.id
      var above = taskInsertionAbove
      if let card = try boardCardBesideCrossColumnSubtask(reference, inColumn: boardColumn, store: store) {
        (parentID, adjacentID, above) = (card.parentID, card.adjacentID, false)
      }
      let task = try store.createTask(capturing: title, listId: reference.listId,
        parentTaskId: parentID,
        kanbanColumn: viewMode == .board ? boardColumn : nil,
        adjacentTaskId: adjacentID, above: above)
      // The board draws a subtask as a row on its parent's card, so it stays
      // put rather than opening the parent to show it.
      if taskInsertionIsChild && viewMode != .board { scopeTaskID = reference.id }
      selectedTaskID = task.id
      taskInsertionReference = task
      taskInsertionAbove = false
      taskInsertionIsChild = false
      reloadOutline()
    }
  }

  /// Where a task typed beside a subtask's own card goes: a card filed in
  /// another column than its parent's is drawn as a card there, linked back
  /// to its parent's row, and a task added beside it is a plain card of that
  /// column rather than another child of the parent over in the first one.
  ///
  /// The cards filed from another column's tasks are drawn after the
  /// column's plain cards, so the new one goes at the foot of those — the
  /// place nearest the card it was typed beside — and among the board's top
  /// level. Nil for anything else, a subtask row drawn on its parent's card
  /// included, which keeps adding a sibling there.
  private func boardCardBesideCrossColumnSubtask(
    _ reference: WorkspaceTask, inColumn columnID: String?, store: WorkspaceStore
  ) throws -> (parentID: String?, adjacentID: String?)? {
    guard viewMode == .board, !taskInsertionIsChild, !boardDraftIsSubtaskRow,
      boardCrossColumnTasks.contains(where: { $0.id == reference.id })
    else { return nil }
    // The level the board's cards are at: in a folder or Everything, the
    // list's own visible root; in one list, the board's parent.
    let parentID = isMultiListScope
      ? try lists.first { $0.id == reference.listId }.flatMap { try store.visibleRootParentTaskID(for: $0) }
      : boardParentTaskID
    let plainCards = Set(
      boardTasks.lazy.filter { $0.parentTaskId == parentID && $0.listId == reference.listId }.map(\.id))
    let lastPlainCard = boardColumns.first { $0.id == columnID }
      .flatMap { tasks(in: $0).last { plainCards.contains($0.id) } }
    return (parentID, lastPlainCard?.id)
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
    if let filter = selectedFilterList { return filter.name }
    if isEverythingSelected { return "Everything" }
    if let folder = scopedFolder { return folder.name }
    return scopeTask?.title ?? selectedList?.name ?? "Board"
  }

  /// The way down to the opened task, outermost first: its list, then each
  /// task above it. Empty at a list's own root. The header draws it before
  /// the title as a breadcrumb — `Errands / Plan my Birthday` — where it used
  /// to print only the parent, after the title, behind a back chevron.
  var scopeTrail: [ScopeCrumb] {
    guard let scope = scopeTask else { return [] }
    var ancestors: [WorkspaceTask] = []
    var visited: Set<String> = [scope.id]
    var parentID = scope.parentTaskId
    while let id = parentID, visited.insert(id).inserted, let parent = task(withID: id) {
      ancestors.insert(parent, at: 0)
      parentID = parent.parentTaskId
    }
    let list = list(for: scope) ?? selectedList
    return (list.map { [ScopeCrumb(id: "list:\($0.id)", title: $0.name, task: nil)] } ?? [])
      + ancestors.map { ScopeCrumb(id: $0.id, title: $0.title, task: $0) }
  }

  /// Goes to a crumb: a task opens as the board or outline it heads; the list
  /// goes back to its root.
  func openCrumb(_ crumb: ScopeCrumb) {
    if let task = crumb.task {
      enterTask(task)
    } else {
      while scopeTask != nil { leaveTaskScope() }
    }
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
    // A fold changes the rows outside any kept index.
    appliedBoardIndexKey = nil
    var index: [String: BoardColumnRows] = [:]
    var columns: [[(id: String, rowIDs: [String])]] = []
    for column in boardColumns {
      let cards = tasks(in: column).map { card in
        (id: card.id, rowIDs: boardTreeRows(of: card).map(\.task.id))
      }
      columns.append(cards)
      index[column.id] = BoardColumnRows(cards: cards)
    }
    if boardRowsByColumn != index { boardRowsByColumn = index }
    rebuildBoardLinks(columns: columns)
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

  /// The column a task is drawn in: where a rule column or an entered card's
  /// floor puts it, else its filed column, else the first.
  func column(for task: WorkspaceTask) -> WorkspaceKanbanColumn? {
    if let placed = boardColumnPlacements[task.id], let column = boardColumnsByID[placed] { return column }
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
  ///
  /// Kept per board shape (`boardShapeGeneration`), columns and folds, so
  /// going back to a scope whose board is resident takes its index as it
  /// was rather than sorting thousands of cards into columns again.
  func rebuildBoardIndex() {
    let key = boardShapeGeneration.map {
      BoardIndexMemo.Key(
        generation: $0, columns: boardColumns, placements: boardColumnPlacements, folded: foldedTaskIDs)
    }
    if let key, let memo = boardIndexMemos.last(where: { $0.key == key }) {
      // Already on screen: nothing moved.
      guard appliedBoardIndexKey != key else { return }
      boardColumnsByID = memo.columnsByID
      boardVisibleTaskIDs = memo.visible
      boardTasksByColumn = memo.byColumn
      matrixQuadrants = memo.quadrants
      boardRowsByColumn = memo.rowsByColumn
      if boardLinks != memo.links { boardLinks = memo.links }
      appliedBoardIndexKey = key
      return
    }
    let byID = Dictionary(boardColumns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    if boardColumnsByID != byID { boardColumnsByID = byID }
    let tasks = boardTasks + boardCrossColumnTasks
    let visible = Set(tasks.map(\.id))
    if boardVisibleTaskIDs != visible { boardVisibleTaskIDs = visible }
    let grouped = Dictionary(grouping: tasks) { task in
      column(for: task)?.id ?? ""
    }
    if boardTasksByColumn != grouped { boardTasksByColumn = grouped }
    let quadrants = MatrixQuadrantIndex(
      boardTasks,
      position: { task in
        let position = matrixPosition(for: task)
        return (position.urgency, position.importance)
      },
      rank: { matrixPosition(for: $0).rank })
    if matrixQuadrants != quadrants { matrixQuadrants = quadrants }
    rebuildBoardRowIndex()
    appliedBoardIndexKey = key
    guard let key else { return }
    boardIndexMemos.removeAll { $0.key.generation == key.generation }
    boardIndexMemos.append(BoardIndexMemo(
      key: key, columnsByID: byID, visible: visible, byColumn: grouped, quadrants: quadrants,
      rowsByColumn: boardRowsByColumn, links: boardLinks))
    if boardIndexMemos.count > scopeCache.capacity { boardIndexMemos.removeFirst() }
  }

  /// The column a visible card sits in, by id alone — so the board can ask
  /// where the selection is without resolving the selected task.
  func boardColumnID(forTaskID id: String) -> String? {
    guard boardVisibleTaskIDs.contains(id) else { return nil }
    if let placed = boardColumnPlacements[id], boardColumnsByID[placed] != nil { return placed }
    let columnID = boardTaskColumns[id] ?? WorkspaceKanbanColumn.blitzitDefaults[0].id
    return (boardColumnsByID[columnID] ?? boardColumns.first)?.id
  }

  /// Files a card, or a subtask row, in another column, and with it every
  /// subtask drawn on it there. Those were filed in the column it is leaving,
  /// and left behind they stood in the old column as cards of their own,
  /// linked back across the board to the card that had gone on.
  func moveTask(_ task: WorkspaceTask, toKanbanColumn column: WorkspaceKanbanColumn) {
    guard let store else { return }
    let moving = tasksMovingWithColumnChange(of: task)
    // Through the core, which edits a task dropped into a rule column to
    // match it, and refuses a move the rules would put straight back.
    let key = boardConfigurationKey
    perform {
      try store.moveToBoardColumn(key: key, taskIDs: moving, columnID: column.id)
      reloadBoard()
    }
  }

  /// The task and the subtasks filed in the column it stands in now.
  private func tasksMovingWithColumnChange(of task: WorkspaceTask) -> [String] {
    guard let from = boardMoveColumn(for: task) else { return [task.id] }
    return WorkspaceBoardShape.tasksMovingWithColumnChange(
      of: task.id, from: from.id, columns: boardTaskColumns, parents: boardTaskParents)
  }

  func placeTask(_ task: WorkspaceTask, before target: WorkspaceTask) {
    guard let store, task.id != target.id else { return }
    guard task.listId == target.listId, task.parentTaskId == target.parentTaskId else {
      errorMessage = "To reorder these cards, they must be siblings in the same project. Drag to a column or list to move them."
      return
    }
    let destinationColumn = column(for: target)
    let destination = destinationColumn?.id
    let changesColumn = destination.map { boardMoveColumn(for: task)?.id != $0 } ?? false
    // A rule column is not filed into: the order is kept, and the core
    // edits the task to match the column, or refuses.
    if let destinationColumn, destinationColumn.isRuleColumn {
      let key = boardConfigurationKey
      perform {
        try store.moveTaskBefore(id: task.id, targetId: target.id)
        if changesColumn { try store.moveToBoardColumn(key: key, taskIDs: [task.id], columnID: destinationColumn.id) }
        reloadBoard()
      }
      return
    }
    // Dropped among another column's cards, the card takes the subtasks
    // drawn on it, as a move to the column does.
    let carried = changesColumn ? Array(tasksMovingWithColumnChange(of: task).dropFirst()) : []
    perform {
      if !carried.isEmpty { try store.setKanbanColumn(destination, for: carried) }
      try store.moveTaskBefore(id: task.id, targetId: target.id, kanbanColumn: destination)
      reloadBoard()
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

  /// Files a task in a quadrant before `targetID`, or at its foot when that
  /// is nil: a drop at a point, from the quadrant itself or from anywhere
  /// else on the matrix. The quadrant is renumbered in the order it is
  /// drawn, so the task stays where it was put.
  func placeTaskInMatrix(
    _ task: WorkspaceTask, in cell: MatrixQuadrantIndex<WorkspaceTask>.Cell, before targetID: String?
  ) {
    guard let store else { return }
    let current = matrixQuadrants.items(in: cell).map(\.id)
    let order = MatrixQuadrantOrder.moving(task.id, before: targetID, in: current)
    let position = matrixPosition(for: task)
    // Dropped back where it already was: nothing to write, and no undo step.
    guard order != current || position.urgency != cell.urgency || position.importance != cell.importance
    else { return }
    perform {
      try store.placeInMatrix(
        taskId: task.id, urgency: cell.urgency, importance: cell.importance, order: order)
      reloadBoard()
    }
  }

  /// `⌥↑`/`⌥↓` on the matrix: the selection a place up or down its quadrant.
  /// An unplaced task has no order of its own to move in, so it stays put.
  func moveSelectedTaskWithinQuadrant(by offset: Int) {
    guard let task = selectedTask, let store else { return }
    let position = matrixPosition(for: task)
    guard let urgency = position.urgency, let importance = position.importance else { return }
    let cell = MatrixQuadrantIndex<WorkspaceTask>.Cell(urgency: urgency, importance: importance)
    guard let order = MatrixQuadrantOrder.stepping(
      task.id, by: offset, in: matrixQuadrants.items(in: cell).map(\.id))
    else { return }
    perform {
      try store.placeInMatrix(taskId: task.id, urgency: urgency, importance: importance, order: order)
      reloadBoard()
    }
  }
}

/// One step of the header's breadcrumb.
struct ScopeCrumb: Identifiable, Equatable {
  let id: String
  let title: String
  /// Nil for the list at the root of the trail.
  let task: WorkspaceTask?
}
