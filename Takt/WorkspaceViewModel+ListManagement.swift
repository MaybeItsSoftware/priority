import Foundation
import TaktCore
import TaktWorkspace

/// Creating, moving and presenting lists and folders: the creation and move
/// overlays, folder expansion and list icons. Split from
/// `WorkspaceViewModel.swift` for size — it is the same type.
extension WorkspaceViewModel {
  static let availableListIcons: [(symbol: String, label: String)] = [
    ("list.bullet", "List"), ("tray", "Inbox"), ("briefcase", "Work"),
    ("graduationcap", "Study"), ("hammer", "Projects"), ("house", "Home"),
    ("heart", "Health"), ("figure.run", "Fitness"), ("book", "Reading"),
    ("music.note", "Music"), ("sailboat", "Sailing"), ("star", "Goals"),
    ("person.2", "People"), ("calendar", "Plans"), ("lightbulb", "Ideas"),
    ("leaf", "Habits"), ("airplane", "Travel"), ("gamecontroller", "Fun")
  ]

  func icon(for list: TaskList) -> String {
    listIcons[list.id] ?? (list.systemRole == .inbox ? "tray" : "list.bullet")
  }

  func setIcon(_ symbol: String, for list: TaskList) {
    listIcons[list.id] = symbol
    UserDefaults.standard.set(listIcons, forKey: "workspaceListIconsV1")
  }

  func requestMoveSelectedTask() {
    if keyboardFocusArea == .sidebar {
      if let scope = scopeTask, scope.isList {
        requestMove(scope)
      } else if let list = selectedList, !list.isSystemList {
        presentOverlay(.move(WorkspaceItemMoveRequest(payload: WorkspaceTaskDrag.listPrefix + list.id,
          title: list.name, sourceListID: list.id, taskID: nil)))
      }
      return
    }
    if selectedTask == nil { selectedTaskID = visibleNavigationTasks.first?.id }
    guard let task = selectedTask else { return }
    requestMove(task)
  }

  func requestMove(_ task: WorkspaceTask) {
    presentOverlay(.move(WorkspaceItemMoveRequest(payload: task.id, title: task.title,
      sourceListID: task.listId, taskID: task.id)))
  }

  func requestCreation(_ kind: WorkspaceCreationKind, in parentFolderID: String? = nil) {
    creationIsNested = false
    creationParentFolderID = parentFolderID
    presentOverlay(.create(kind))
  }

  func requestListCreationForSelection() {
    if keyboardFocusArea == .tasks, !isEverythingSelected, selectedListID != nil {
      requestNestedListCreation(under: scopeTask)
    } else if isNamingInSidebar {
      beginSidebarDraft(.list, in: creationFolderIDForSelection)
    } else {
      requestCreation(.list, in: creationFolderIDForSelection)
    }
  }

  func requestFolderCreationForSelection() {
    if isNamingInSidebar {
      beginSidebarDraft(.folder, in: creationFolderIDForSelection)
    } else {
      requestCreation(.folder, in: creationFolderIDForSelection)
    }
  }

  /// From the sidebar a new list or folder is named in its row, where it will
  /// be; from anywhere else, where there is no row to type in, in the sheet.
  private var isNamingInSidebar: Bool {
    keyboardFocusArea == .sidebar && isListsPaneVisible
  }

  // MARK: - Naming a new list or folder in place

  /// Draws a name field in the sidebar where the new list or folder will
  /// appear — the end of `folderID`, which is opened if it was closed — the
  /// way Zed's project panel makes a new file.
  func beginSidebarDraft(_ kind: WorkspaceCreationKind, in folderID: String?) {
    if !isListsPaneVisible { showLeftDock(.lists) }
    renamingSidebarItemID = nil
    var ancestorID = folderID
    var visited = Set<String>()
    while let id = ancestorID, visited.insert(id).inserted, let folder = folders.first(where: { $0.id == id }) {
      setFolderExpanded(folder, expanded: true)
      ancestorID = folder.parentFolderId
    }
    sidebarDraft = WorkspaceSidebarDraft(kind: kind, folderID: folderID)
  }

  /// Return in the draft row: makes the list or folder, with the cursor on it.
  func commitSidebarDraft(named name: String) {
    guard let draft = sidebarDraft, let store, let workspace else { return }
    sidebarDraft = nil
    switch draft.kind {
    case .list:
      createList(named: name, in: draft.folderID)
    case .folder:
      perform {
        let folder = try store.createFolder(workspaceId: workspace.id, name: name, parentFolderId: draft.folderID)
        try load()
        selectFolder(folder)
      }
    }
    requestKeyboardFocus(.sidebar)
  }

  /// Esc in the draft row, or leaving it empty: nothing was made, so nothing
  /// is removed — the row goes and the keyboard is back on the sidebar.
  func cancelSidebarDraft() {
    guard sidebarDraft != nil else { return }
    sidebarDraft = nil
    requestKeyboardFocus(.sidebar)
  }

  /// Where a new list or folder goes: into the folder you are on, or — from a
  /// list in the sidebar — beside it, in its folder, the way Zed's project
  /// panel makes a new file next to the one selected.
  private var creationFolderIDForSelection: String? {
    if let selectedFolderID { return selectedFolderID }
    guard keyboardFocusArea == .sidebar, !isEverythingSelected else { return nil }
    return selectedList?.folderId
  }

  /// ⌘← and ⌘→ in the sidebar, Zed's collapse and expand all. Collapsing
  /// under the cursor moves it to the top-level folder it was inside, so it
  /// is never left on a row that is no longer drawn.
  func setAllFoldersExpanded(_ expanded: Bool) {
    if expanded {
      expandedFolderIDs = Set(folders.map(\.id))
      return
    }
    var topFolderID = selectedFolderID ?? selectedList?.folderId
    while let id = topFolderID, let parent = folders.first(where: { $0.id == id })?.parentFolderId {
      topFolderID = parent
    }
    expandedFolderIDs = []
    if let topFolderID, let folder = folders.first(where: { $0.id == topFolderID }),
      sidebarCursorRow?.kind != .folder(topFolderID) {
      selectFolder(folder)
    }
  }

  func createList(named name: String, in folderId: String? = nil) {
    guard let store, let workspace else { return }
    do {
      let list = try store.createList(workspaceId: workspace.id, name: name, folderId: folderId)
      try load()
      selectList(list.id)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func createFolder(named name: String, in parentFolderId: String? = nil) {
    guard let store, let workspace else { return }
    perform {
      _ = try store.createFolder(workspaceId: workspace.id, name: name, parentFolderId: parentFolderId)
      try load()
    }
  }

  func isFolderExpanded(_ folder: ListFolder) -> Bool {
    expandedFolderIDs.contains(folder.id)
  }

  func setFolderExpanded(_ folder: ListFolder, expanded: Bool) {
    if expanded {
      expandedFolderIDs.insert(folder.id)
    } else {
      expandedFolderIDs.remove(folder.id)
    }
  }

  func toggleFolderExpansion(_ folder: ListFolder) {
    setFolderExpanded(folder, expanded: !isFolderExpanded(folder))
  }
}
