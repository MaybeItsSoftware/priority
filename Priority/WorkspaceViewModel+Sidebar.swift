import Foundation
import PriorityWorkspace

/// Managing the sidebar's own contents: lists, folders, archiving and
/// deletion. Split from `WorkspaceViewModel.swift` only for size.
@MainActor
extension WorkspaceViewModel {
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
    } else if let list = selectedList {
      beginRenaming(.list(list))
    }
  }

  func cancelRenaming() {
    renamingSidebarItemID = nil
  }

  func renameList(_ list: TaskList, to name: String) {
    guard let store else { return }
    renamingSidebarItemID = nil
    perform {
      try store.renameList(id: list.id, name: name)
      try load()
    }
  }

  func renameFolder(_ folder: ListFolder, to name: String) {
    renamingSidebarItemID = nil
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
    } else if let list = selectedList {
      showSettings(for: list)
    }
  }

  func archiveSelectedList() {
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
    guard let store else { return 0 }
    return (try? store.outline(in: list.id).count) ?? 0
  }
}
