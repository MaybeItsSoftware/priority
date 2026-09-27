import Foundation
import PriorityCore
import PriorityWorkspace

/// Being in a folder.
///
/// A folder used to be a container you could select but not read: choosing one
/// moved the sidebar's mark and left the main pane showing whichever list you
/// had been in before, so the one thing a folder obviously means — these lists,
/// together — was the one thing it could not show you.
///
/// It is now a scope, sitting between Everything and a single list and behaving
/// like the former narrowed to the latter. Everything already had all the
/// machinery for a view drawn from several lists at once: a combined query, a
/// per-task badge naming the list a task came from, and a chosen destination
/// for new tasks. A folder reuses all three rather than growing its own.
@MainActor
extension WorkspaceViewModel {
  var scopedFolder: ListFolder? {
    guard let selectedFolderID else { return nil }
    return folders.first { $0.id == selectedFolderID }
  }

  /// The lists a folder scope stands for, in sidebar order.
  var folderScopeListIDs: [String]? {
    guard let selectedFolderID else { return nil }
    return WorkspaceSidebarOutline.listIDs(
      inFolder: selectedFolderID,
      folders: folders.map { SidebarFolderDescriptor(id: $0.id, parentFolderID: $0.parentFolderId) },
      lists: lists.map { SidebarListDescriptor(id: $0.id, folderID: $0.folderId) })
  }

  /// Whether the pane is drawing from more than one list.
  ///
  /// The question several views were asking as `isEverythingSelected`, which
  /// was the same question only for as long as Everything was the only scope
  /// that could answer yes.
  var isMultiListScope: Bool {
    isEverythingSelected || selectedFolderID != nil
  }

  /// Where a new task goes while a folder is in scope: the remembered
  /// destination when it is still inside the folder, otherwise the first list
  /// in it. Adding to a folder has to land in one of its lists, and silently
  /// adding to a list you left behind would be worse than refusing.
  var folderScopeDestinationID: String? {
    guard let ids = folderScopeListIDs, !ids.isEmpty else { return nil }
    if let newTaskListID, ids.contains(newTaskListID) { return newTaskListID }
    return ids.first
  }

  /// Puts a folder in scope and draws it.
  ///
  /// The view mode follows Everything's: a folder is a pile of several lists,
  /// and the outline is the one mode that cannot show where a task came from,
  /// so the board is the honest default. A mode you are already in that can
  /// show it is left alone.
  func enterFolderScope(_ folder: ListFolder) {
    taskEditor.flush()
    leaveFullPaneScreens()
    selectedFolderID = folder.id
    isEverythingSelected = false
    UserDefaults.standard.set(false, forKey: Self.everythingScopeKey)
    selectedListID = nil
    scopeTaskID = nil
    focusedBoardColumnID = nil
    taskInsertionReference = nil
    desktopShortcutSequence.reset()
    selectedTaskID = nil
    newTaskListID = folderScopeDestinationID
    if viewMode == .today { viewMode = .board }
    reloadOutline(refreshSidebar: false)
  }
}

@MainActor
extension WorkspaceViewModel {
  /// The lists the current scope draws from, in sidebar order.
  ///
  /// Everything is every list; a folder is its own; a single list is itself.
  /// The views that group a combined pane by list read this rather than
  /// `lists`, so a folder shows the lists it contains and not the ones it
  /// does not.
  var scopeLists: [TaskList] {
    if let ids = folderScopeListIDs {
      let byID = Dictionary(lists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      return ids.compactMap { byID[$0] }
    }
    if isEverythingSelected { return lists }
    return selectedList.map { [$0] } ?? []
  }
}
