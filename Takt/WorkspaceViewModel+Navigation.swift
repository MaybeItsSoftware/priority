import Foundation
import TaktCore
import TaktWorkspace

/// Moving the selection about: within a surface, between surfaces, and back
/// out of whatever the last key put you into.
///
/// Split out of `WorkspaceViewModel` because navigation is a subject on its
/// own — every mode has its own idea of what "the next one" means — and
/// because the type it came from had grown past the point where one more
/// method could be found in it.
extension WorkspaceViewModel {
  func moveTaskSelection(by offset: Int) {
    let rows = navigationRowIDs()
    guard !rows.isEmpty else { return }
    guard let currentTaskID = selectedTaskID, let index = rows.firstIndex(of: currentTaskID) else {
      selectedTaskID = offset < 0 ? rows.last : rows.first
      return
    }
    selectedTaskID = rows[CursorStepping.index(from: index, by: offset, count: rows.count)]
  }

  /// What up and down walk. On the board that is the active column's cards
  /// with the subtask rows drawn on them, and the column is pinned while the
  /// keys walk it, so stepping onto a subtask that is also a card elsewhere
  /// does not jump the keyboard to that other column.
  func navigationRowIDs() -> [String] {
    guard viewMode == .board else { return visibleNavigationTasks.map(\.id) }
    guard let column = boardColumns.first(where: { $0.id == activeBoardColumnID }) else { return [] }
    focusedBoardColumnID = column.id
    return boardRowIDs(in: column)
  }

  func selectAdjacentTask(by offset: Int) {
    moveTaskSelection(by: offset)
  }

  func selectTaskInAdjacentColumn(from task: WorkspaceTask, by offset: Int) {
    focusAdjacentBoardColumn(from: activeBoardColumnID, by: offset)
  }

  func focusAdjacentBoardColumn(from columnID: String? = nil, by offset: Int) {
    guard viewMode == .board,
      let index = boardColumns.firstIndex(where: { $0.id == (columnID ?? activeBoardColumnID) })
    else { return }
    let destination = index + offset
    guard boardColumns.indices.contains(destination) else {
      if destination < 0 { returnToCurrentListInSidebar() }
      return
    }
    let column = boardColumns[destination]
    focusedBoardColumnID = column.id
    selectedTaskID = tasks(in: column).first?.id
  }

  func moveTaskToAdjacentColumn(_ task: WorkspaceTask, by offset: Int) {
    guard viewMode == .board, isTaskVisibleOnBoard(task), let column = column(for: task),
      let index = boardColumns.firstIndex(where: { $0.id == column.id })
    else { return }
    let destination = min(max(0, index + offset), boardColumns.count - 1)
    guard destination != index else { return }
    moveTask(task, toKanbanColumn: boardColumns[destination])
  }

  func moveSelectedTaskToAdjacentColumn(by offset: Int) {
    guard let task = selectedTask else { return }
    moveTaskToAdjacentColumn(task, by: offset)
  }

  func moveListSelection(by offset: Int) {
    guard !lists.isEmpty else { return }
    if isEverythingSelected {
      if offset > 0 { selectList(lists[0].id) }
      return
    }
    guard let selectedListID, let index = lists.firstIndex(where: { $0.id == selectedListID }) else {
      selectEverything()
      return
    }
    if index + offset < 0 {
      selectEverything()
    } else {
      selectList(lists[min(index + offset, lists.count - 1)].id)
    }
  }

  func cycleNewTaskDestination(by offset: Int) {
    // A folder's lists: Everything's new tasks go to the inbox, so a folder
    // is the one scope left with a choice to make.
    let lists = scopeLists
    guard selectedFolderID != nil, !lists.isEmpty else { return }
    let current = lists.firstIndex { $0.id == folderScopeDestinationID } ?? 0
    newTaskListID = lists[min(max(0, current + offset), lists.count - 1)].id
  }

  func moveFolderSelection(by offset: Int) {
    let ordered = orderedFolders
    guard !ordered.isEmpty else { return }
    guard let selectedFolderID, let index = ordered.firstIndex(where: { $0.id == selectedFolderID }) else {
      selectFolder(ordered.first!)
      return
    }
    selectFolder(ordered[min(max(0, index + offset), ordered.count - 1)])
  }

  private var orderedFolders: [ListFolder] {
    var result: [ListFolder] = []
    var visited = Set<String>()
    func appendChildren(of parentID: String?) {
      for folder in folders where folder.parentFolderId == parentID && visited.insert(folder.id).inserted {
        result.append(folder)
        appendChildren(of: folder.id)
      }
    }
    appendChildren(of: nil)
    return result
  }

  /// Return on Today: start the task under the cursor. Pressing it on a row
  /// is the answer to the question the focus screen asks — is this available
  /// — so it starts unconditionally, and on the running row it means done.
  func startSelectedDayTask() {
    guard let task = selectedTask else { return }
    if task.id == activeFocusTask?.id {
      requestFocusCompletion()
    } else if activeFocusSession != nil {
      addToFocusQueue(task)
    } else {
      startFocus(on: task, override: true)
    }
  }

  /// Ticking off on Today. A task that owes the day a contribution gets the
  /// contribution rather than being closed — the distinction the daily model
  /// rests on — and the running task is finished through its block, so the
  /// minutes on the clock are kept.
  func tickOffSelectedDayTask() {
    guard let task = selectedTask else { return }
    if task.id == activeFocusTask?.id {
      requestFocusCompletion()
    } else if isDailyProgressTask(task) {
      if !isDailyProgressComplete(task) { toggleDailyProgress(task) }
    } else {
      toggleTask(task)
    }
  }

  func enterSelectedTask() {
    guard let task = selectedTask else { return }
    enterTask(task)
    selectedTaskID = nil
  }

  func enterTaskSurfaceFromSidebar() {
    if viewMode == .board {
      let backlog = boardColumns.first { $0.id == "backlog" } ?? boardColumns.first
      focusedBoardColumnID = backlog?.id
      selectedTaskID = backlog.flatMap { tasks(in: $0).first?.id }
    } else {
      selectedTaskID = visibleNavigationTasks.first?.id
    }
    requestKeyboardFocus(.tasks)
  }

  func returnToCurrentListInSidebar() {
    // A folder you are working in stays open, with the cursor on its row; a
    // list puts the cursor on the list. Either way the stored cursor is let
    // go, since it may name a row you walked off long ago.
    var folderID = selectedFolderID.flatMap { id in folders.first { $0.id == id }?.parentFolderId }
      ?? selectedList?.folderId
    sidebarCursorID = nil
    var visited = Set<String>()
    while let id = folderID, visited.insert(id).inserted,
      let folder = folders.first(where: { $0.id == id }) {
      setFolderExpanded(folder, expanded: true)
      folderID = folder.parentFolderId
    }
    requestKeyboardFocus(.sidebar)
  }

  /// Left steps out by one: out of a task's children while you are inside a
  /// task, and otherwise out of the list to its row in the sidebar.
  ///
  /// It used to take two more presses on the way — one to clear the
  /// selection and one to widen the list to Everything — so ← out of a list
  /// landed on a different view rather than back on the list.
  func leaveSelectedTaskScope() {
    if scopeTaskID != nil {
      leaveTaskScope()
    } else {
      returnToCurrentListInSidebar()
    }
  }

  func toggleSelectedTask() {
    guard let task = selectedTask else { return }
    toggleTask(task)
  }

  func focusSelectedTask() {
    guard let task = selectedTask else { return }
    if activeFocusSession == nil {
      startFocus(on: task)
    } else {
      addToFocusQueue(task)
    }
  }

  func dismissKeyboardContext() {
    if scopeTaskID != nil {
      leaveTaskScope()
    } else {
      selectedTaskID = nil
    }
  }
}
