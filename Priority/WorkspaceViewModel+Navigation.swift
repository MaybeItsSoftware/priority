import Foundation
import PriorityCore
import PriorityWorkspace

/// Moving the selection about: within a surface, between surfaces, and back
/// out of whatever the last key put you into.
///
/// Split out of `WorkspaceViewModel` because navigation is a subject on its
/// own — every mode has its own idea of what "the next one" means — and
/// because the type it came from had grown past the point where one more
/// method could be found in it.
extension WorkspaceViewModel {
  func moveTaskSelection(by offset: Int) {
    let visibleTasks = viewMode == .board
      ? boardColumns.first(where: { $0.id == activeBoardColumnID }).map { tasks(in: $0) } ?? []
      : visibleNavigationTasks
    guard !visibleTasks.isEmpty else { return }
    guard let currentTaskID = selectedTaskID,
      let index = visibleTasks.firstIndex(where: { $0.id == currentTaskID })
    else {
      selectedTaskID = offset < 0 ? visibleTasks.last?.id : visibleTasks.first?.id
      return
    }
    selectedTaskID = visibleTasks[min(max(0, index + offset), visibleTasks.count - 1)].id
  }

  func selectAdjacentTask(by offset: Int) {
    moveTaskSelection(by: offset)
  }

  func selectTaskInAdjacentColumn(from task: WorkspaceTask, by offset: Int) {
    focusAdjacentBoardColumn(from: column(for: task)?.id, by: offset)
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
    guard isEverythingSelected, !lists.isEmpty else { return }
    let current = lists.firstIndex { $0.id == newTaskListID } ?? 0
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

  private enum SidebarNavigationTarget: Equatable {
    case everything
    case list(String)
    case nestedList(String)
    case folder(String)
  }

  /// Mirrors the visible sidebar order: Everything, Inbox, pinned shortcuts,
  /// folders and their contents, then the ungrouped lists.
  private var sidebarNavigationTargets: [SidebarNavigationTarget] {
    var result: [SidebarNavigationTarget] = [.everything]
    var visited = Set<String>()
    func appendList(_ list: TaskList) {
      result.append(.list(list.id))
      result += nestedLists.filter { $0.task.listId == list.id }.map { .nestedList($0.id) }
    }
    func appendFolder(_ folder: ListFolder) {
      guard visited.insert(folder.id).inserted else { return }
      result.append(.folder(folder.id))
      guard expandedFolderIDs.contains(folder.id) else { return }
      for list in lists where list.folderId == folder.id && list.systemRole != .inbox {
        appendList(list)
      }
      for child in folders where child.parentFolderId == folder.id {
        appendFolder(child)
      }
    }
    if let inbox = inboxList { appendList(inbox) }
    result += promotedLists.map { .nestedList($0.id) }
    for folder in folders where folder.parentFolderId == nil { appendFolder(folder) }
    for list in lists where list.folderId == nil && list.systemRole != .inbox { appendList(list) }
    return result
  }

  func moveSidebarSelection(by offset: Int) {
    let targets = sidebarNavigationTargets
    guard !targets.isEmpty else { return }
    let current: SidebarNavigationTarget? = if let selectedFolderID {
      .folder(selectedFolderID)
    } else if isEverythingSelected {
      .everything
    } else if let scope = scopeTask, scope.isList {
      .nestedList(scope.id)
    } else if let selectedListID {
      .list(selectedListID)
    } else {
      nil
    }
    let index = current.flatMap { targets.firstIndex(of: $0) }
      ?? (offset < 0 ? targets.count : -1)
    let target = targets[min(max(0, index + offset), targets.count - 1)]
    switch target {
    case .everything: selectEverything()
    case .list(let id): selectList(id)
    case .nestedList(let id):
      if let task = task(withID: id) { selectNestedList(task) }
    case .folder(let id):
      if let folder = folders.first(where: { $0.id == id }) { selectFolder(folder) }
    }
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
    selectedFolderID = nil
    var folderID = selectedList?.folderId
    var visited = Set<String>()
    while let id = folderID, visited.insert(id).inserted,
      let folder = folders.first(where: { $0.id == id }) {
      setFolderExpanded(folder, expanded: true)
      folderID = folder.parentFolderId
    }
    requestKeyboardFocus(.sidebar)
  }

  func leaveSelectedTaskScope() {
    if scopeTaskID != nil {
      leaveTaskScope()
    } else if selectedTaskID == nil && !isEverythingSelected {
      selectEverything()
    } else {
      selectedTaskID = nil
      isInspectorVisible = false
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
    if showsKeyboardHelp {
      showsKeyboardHelp = false
    } else if isInspectorVisible {
      isInspectorVisible = false
      requestKeyboardFocus(.tasks)
    } else if scopeTaskID != nil {
      leaveTaskScope()
    } else {
      selectedTaskID = nil
    }
  }
}
