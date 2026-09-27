import Foundation
import PriorityWorkspace

/// Managing the sidebar's own contents: lists, folders, archiving and
/// deletion. Split from `WorkspaceViewModel.swift` only for size.
@MainActor
extension WorkspaceViewModel {
  func itemSymbol(for task: WorkspaceTask) -> String {
    task.isList ? (listIcons[task.id] ?? "list.bullet") : (task.status == .open ? "circle" : "checkmark.circle.fill")
  }

  func setNestedListIcon(_ symbol: String, for task: WorkspaceTask) {
    listIcons[task.id] = symbol
    UserDefaults.standard.set(listIcons, forKey: "workspaceListIconsV1")
  }

  func openItemList(_ task: WorkspaceTask) {
    taskEditor.flush()
    batchingRefreshes {
      enterTask(task)
      selectedTaskID = nil
      requestKeyboardFocus(.tasks)
    }
  }

  func moveIntoNestedList(_ task: WorkspaceTask, parent: WorkspaceTask) {
    guard let store else { return }
    taskEditor.flush()
    perform {
      try store.moveTask(id: task.id, toListId: parent.listId, parentTaskId: parent.id)
      try load()
    }
  }

  func moveDroppedItem(_ payload: String, toListID listID: String, parentTaskID: String? = nil) {
    guard let store else { return }
    taskEditor.flush()
    perform {
      if payload.hasPrefix(WorkspaceTaskDrag.listPrefix) {
        let sourceID = String(payload.dropFirst(WorkspaceTaskDrag.listPrefix.count))
        guard sourceID != listID else { return }
        let oldIcon = listIcons[sourceID]
        let nested = try store.nestList(id: sourceID, inListId: listID, parentTaskId: parentTaskID)
        if let oldIcon { setNestedListIcon(oldIcon, for: nested) }
        if selectedListID == sourceID {
          selectedListID = listID
          if scopeTaskID == nil { scopeTaskID = nested.id }
        }
      } else {
        guard let task = try store.task(id: payload), task.id != parentTaskID else { return }
        try store.moveTask(id: task.id, toListId: listID, parentTaskId: parentTaskID, toVisibleRoot: parentTaskID == nil)
        if let scopeID = scopeTaskID, let scope = try store.task(id: scopeID), scope.listId != selectedListID {
          scopeTaskID = nil
        }
        if !isEverythingSelected && listID != selectedListID && selectedTaskID == task.id {
          selectedTaskID = nil
          isInspectorVisible = false
        }
      }
      try load()
      if let selectedID = selectedTaskID, !visibleNavigationTasks.contains(where: { $0.id == selectedID }) {
        selectedTaskID = visibleNavigationTasks.first?.id
      }
    }
  }

  /// A sidebar item dropped between two rows: put it there.
  ///
  /// `beforeID` of nil means the end of that group. Anything that is not a
  /// list or a folder — a task drag passing over the sidebar — is ignored
  /// rather than guessed at.
  func placeDroppedItem(_ payload: String, before beforeID: String?, inFolderID folderID: String?) {
    guard let store, let item = WorkspaceTaskDrag.sidebarItemID(from: payload) else { return }
    taskEditor.flush()
    perform {
      if item.isFolder {
        try store.placeFolder(id: item.id, before: beforeID, inParentFolderId: folderID)
      } else {
        try store.placeList(id: item.id, before: beforeID, inFolderId: folderID)
      }
      if let folderID, let folder = folders.first(where: { $0.id == folderID }) {
        setFolderExpanded(folder, expanded: true)
      }
      try load()
    }
  }

  func moveDroppedItem(_ payload: String, toFolderID folderID: String?) {
    guard let store else { return }
    taskEditor.flush()
    perform {
      if payload.hasPrefix(WorkspaceTaskDrag.listPrefix) {
        let listID = String(payload.dropFirst(WorkspaceTaskDrag.listPrefix.count))
        try store.moveList(id: listID, toFolderId: folderID)
      } else {
        let oldTask = try store.task(id: payload)
        let list = try store.moveTaskToFolder(id: payload, folderId: folderID)
        if let oldTask, oldTask.isList, let symbol = listIcons[oldTask.id] { setIcon(symbol, for: list) }
        if scopeTaskID == payload || selectedTaskID == payload {
          selectedListID = list.id
          scopeTaskID = nil
        } else if let scopeID = scopeTaskID, let scope = try store.task(id: scopeID), scope.listId != selectedListID {
          scopeTaskID = nil
        }
      }
      var ancestorID: String? = folderID
      var visited = Set<String>()
      while let id = ancestorID, visited.insert(id).inserted, let folder = folders.first(where: { $0.id == id }) {
        setFolderExpanded(folder, expanded: true)
        ancestorID = folder.parentFolderId
      }
      try load()
      if let selectedID = selectedTaskID, !visibleNavigationTasks.contains(where: { $0.id == selectedID }) {
        selectedTaskID = visibleNavigationTasks.first?.id
      }
    }
  }
  var promotedLists: [WorkspaceTask] {
    nestedLists.map(\.task).filter { $0.isPromoted == true && $0.status == .open }
  }

  var currentSidebarID: String? {
    if isEverythingSelected { return "priority:everything" }
    if let scope = scopeTask, scope.isList { return scope.id }
    return selectedListID
  }

  /// Whether a sidebar row is the one you are actually on. A folder being
  /// selected takes the mark off the lists, because the folder is then what
  /// the arrow keys are pointed at.
  ///
  /// One predicate rather than the same pair of comparisons at each row: the
  /// background and the label both need the answer, and a row whose outline
  /// and whose name disagreed about being current would be worse than either
  /// cue on its own.
  func isCurrentSidebarRow(_ id: String) -> Bool {
    selectedFolderID == nil && currentSidebarID == id
  }

  /// Marks the sidebar stale; see `refresh(_:)`.
  func reloadNestedLists() {
    refresh(.sidebar)
  }

  func reloadNestedListsNow() {
    guard let store else { return }
    do {
      let index = WorkspaceSidebarIndex(lists: lists, trees: try listTrees(for: lists.map(\.id), store: store))
      if nestedLists != index.nestedLists { nestedLists = index.nestedLists }
      if archivedNestedLists != index.archivedNestedLists { archivedNestedLists = index.archivedNestedLists }
      if listTaskCounts != index.taskCounts { listTaskCounts = index.taskCounts }
      var layout = Hasher()
      for list in lists { layout.combine(list.id); layout.combine(list.folderId) }
      for folder in folders { layout.combine(folder.id); layout.combine(folder.parentFolderId) }
      for item in nestedLists {
        layout.combine(item.id); layout.combine(item.task.parentTaskId); layout.combine(item.task.isPromoted == true)
      }
      let key = layout.finalize()
      if sidebarLayoutKey != key { sidebarLayoutKey = key }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func selectNestedList(_ task: WorkspaceTask) {
    // Any other way of choosing a row moves the keyboard cursor there too,
    // by letting it fall back to whatever is now selected.
    sidebarCursorID = nil

    taskEditor.flush()
    leaveFullPaneScreens()
    selectedFolderID = nil
    batchingRefreshes {
      enterTask(task)
      selectedListID = task.listId
      selectedTaskID = nil
    }
    reportKeyboardFocus(.sidebar)
  }

  func convertItem(_ task: WorkspaceTask) {
    guard let store else { return }
    taskEditor.flush()
    perform {
      try store.setItemKind(task.isList ? .task : .list, for: task.id)
      try load()
    }
  }

  func convertListToTask(_ list: TaskList) {
    guard let store else { return }
    taskEditor.flush()
    perform {
      let task = try store.convertListToTask(id: list.id)
      selectedListID = task.listId
      scopeTaskID = nil
      viewMode = .outline
      try load()
      selectTask(task)
      requestKeyboardFocus(.tasks)
    }
  }

  func toggleCurrentListCompletion() {
    if let scope = scopeTask, scope.isList { toggleTask(scope) }
    else if let list = selectedList, !list.isSystemList { toggleListCompletion(list) }
  }

  func toggleListPromotion(_ task: WorkspaceTask) {
    guard let store, task.isList else { return }
    perform { try store.setNestedListPromoted(task.isPromoted != true, id: task.id); try load() }
  }

  func archiveNestedList(_ task: WorkspaceTask, archived: Bool = true) {
    guard let store else { return }
    taskEditor.flush()
    perform {
      try store.setNestedListArchived(archived, id: task.id)
      if archived, scopeTaskID == task.id { scopeTaskID = task.parentTaskId }
      try load()
    }
  }

  func toggleListCompletion(_ list: TaskList) {
    guard let store else { return }
    perform { try store.setListCompleted(list.completedAt == nil, id: list.id); try load() }
  }

  func requestNestedListCreation(under parent: WorkspaceTask? = nil) {
    guard let listID = parent?.listId ?? selectedListID, let store else { return }
    creationTaskListID = listID
    creationTaskParentID = parent?.id ?? (try? selectedList.flatMap { try store.visibleRootParentTaskID(for: $0) })
    creationIsNested = true
    creationRequest = .list
  }

  func createNestedList(named name: String) {
    guard let store, let listID = creationTaskListID else { return }
    perform {
      let task = try store.createTask(listId: listID, title: name, parentTaskId: creationTaskParentID, kind: .list)
      try load()
      selectNestedList(task)
      requestKeyboardFocus(.tasks)
    }
  }
  func archiveList(_ list: TaskList) {
    guard let store else { return }
    perform {
      try store.setListArchived(true, id: list.id)
      try load()
    }
  }

  func restoreList(_ list: TaskList) {
    guard let store else { return }
    perform {
      try store.setListArchived(false, id: list.id)
      try load()
    }
  }

  func deleteList(_ list: TaskList) {
    guard let store else { return }
    perform {
      try store.deleteList(id: list.id)
      selectedListID = nil
      selectedTaskID = nil
      isInspectorVisible = false
      try load()
    }
  }

  // MARK: - Renaming in place

  /// Turns a sidebar row into a text field. The settings sheet can still
  /// rename, but a name is the one thing people change often enough that
  /// opening a sheet for it is the wrong amount of ceremony.
  func beginRenaming(_ item: WorkspaceSidebarItem) {
    switch item {
    case .list(let list):
      selectList(list.id)
      renamingSidebarItemID = list.id
    case .folder(let folder):
      selectFolder(folder)
      renamingSidebarItemID = folder.id
    }
  }

  /// ⌘R on whatever the sidebar has selected. A folder wins over a list for
  /// the same reason it does everywhere else here: selecting a folder is an
  /// explicit act, where a list is always selected.
  func beginRenamingSelection() {
    if let folder = selectedFolder {
      beginRenaming(.folder(folder))
    } else if let scope = scopeTask, scope.isList {
      taskQuickEditRequest = WorkspaceTaskQuickEditRequest(task: scope, kind: .title)
    } else if let list = selectedList {
      beginRenaming(.list(list))
    }
  }

  func cancelRenaming(itemID: String? = nil) {
    if let itemID, renamingSidebarItemID != itemID { return }
    renamingSidebarItemID = nil
  }

  func renameList(_ list: TaskList, to name: String) {
    guard let store else { return }
    cancelRenaming(itemID: list.id)
    perform {
      try store.renameList(id: list.id, name: name)
      try load()
    }
  }

  func renameFolder(_ folder: ListFolder, to name: String) {
    cancelRenaming(itemID: folder.id)
    updateFolder(folder, name: name)
  }

  func isRenaming(_ item: WorkspaceSidebarItem) -> Bool {
    switch item {
    case .list(let list): return renamingSidebarItemID == list.id
    case .folder(let folder): return renamingSidebarItemID == folder.id
    }
  }

  // MARK: - Archiving and deletion

  func requestDeletion(of item: WorkspaceSidebarItem) {
    pendingSidebarDeletion = item
  }

  func requestDeletionOfSelectedSidebarItem() {
    if let folder = selectedFolder {
      requestDeletion(of: .folder(folder))
    } else if let list = selectedList, !list.isSystemList {
      requestDeletion(of: .list(list))
    }
  }

  func confirmPendingSidebarDeletion() {
    guard let pendingSidebarDeletion else { return }
    self.pendingSidebarDeletion = nil
    switch pendingSidebarDeletion {
    case .list(let list): deleteList(list)
    case .folder(let folder): deleteFolder(folder)
    }
  }

  func showSelectedListSettings() {
    if let folder = selectedFolder {
      showSettings(for: folder)
    } else if let scope = scopeTask, scope.isList {
      selectTask(scope)
      requestKeyboardFocus(.inspector)
    } else if let list = selectedList {
      showSettings(for: list)
    }
  }

  func archiveSelectedList() {
    if let scope = scopeTask, scope.isList { archiveNestedList(scope); return }
    guard let list = selectedList, !list.isSystemList else { return }
    archiveList(list)
  }

  func restoreMostRecentlyArchivedList() {
    guard let list = archivedLists.max(by: { $0.updatedAt < $1.updatedAt }) else { return }
    restoreList(list)
  }

  func showSettings(for list: TaskList) {
    sidebarEditor = .list(list)
  }

  func showSettings(for folder: ListFolder) {
    sidebarEditor = .folder(folder)
  }

  func updateList(_ list: TaskList, name: String, colorHex: String?) {
    guard let store else { return }
    perform {
      try store.updateList(id: list.id, name: name, colorHex: colorHex)
      try load()
    }
  }

  func moveList(_ list: TaskList, toFolderId folderId: String?) {
    guard let store else { return }
    perform {
      try store.moveList(id: list.id, toFolderId: folderId)
      try load()
    }
  }

  func moveListWithinFolder(_ list: TaskList, by offset: Int) {
    guard let store else { return }
    perform {
      try store.moveListWithinFolder(id: list.id, by: offset)
      try load()
    }
  }

  func updateFolder(_ folder: ListFolder, name: String) {
    guard let store else { return }
    perform {
      try store.updateFolder(id: folder.id, name: name)
      try load()
    }
  }

  func moveFolder(_ folder: ListFolder, toParentFolderId parentFolderId: String?) {
    guard let store else { return }
    perform {
      try store.moveFolder(id: folder.id, toParentFolderId: parentFolderId)
      try load()
    }
  }

  func moveFolderWithinSiblings(_ folder: ListFolder, by offset: Int) {
    guard let store else { return }
    perform {
      try store.moveFolderWithinSiblings(id: folder.id, by: offset)
      try load()
    }
  }

  func deleteFolder(_ folder: ListFolder) {
    guard let store else { return }
    perform {
      try store.deleteFolder(id: folder.id)
      try load()
    }
  }

  func taskCount(for list: TaskList) -> Int {
    listTaskCounts[list.id, default: 0]
  }
}
