import Foundation
import TaktCore
import TaktWorkspace

/// Choosing what the main pane shows: a list, Everything, a folder, a task's
/// children, or a view mode. Split from `WorkspaceViewModel.swift` for size —
/// it is the same type.
extension WorkspaceViewModel {
  func selectList(_ id: String) {
    isDraftingTask = false
    // Any other way of choosing a row moves the keyboard cursor there too,
    // by letting it fall back to whatever is now selected.
    sidebarCursorID = nil

    guard lists.contains(where: { $0.id == id }) else { return }
    noteListVisit(leaving: isMultiListScope ? nil : selectedListID, arriving: id)
    taskEditor.flush()
    isEverythingSelected = false
    UserDefaults.standard.set(false, forKey: Self.everythingScopeKey)
    selectedListID = id
    newTaskListID = id
    selectedFolderID = nil
    scopeTaskID = nil
    focusedBoardColumnID = nil
    taskInsertionReference = nil
    desktopShortcutSequence.reset()
    selectedTaskID = nil
    // The inbox is a queue to empty, not a board to plan, so it opens as a
    // flat outline whatever the last list was shown as.
    viewMode = lists.first(where: { $0.id == id })?.systemRole == .inbox ? .outline : .board
    reloadOutline(refreshSidebar: false)
  }

  func selectEverything() {
    // Any other way of choosing a row moves the keyboard cursor there too,
    // by letting it fall back to whatever is now selected.
    sidebarCursorID = nil

    taskEditor.flush()
    if let selectedListID { newTaskListID = selectedListID }
    isEverythingSelected = true
    UserDefaults.standard.set(true, forKey: Self.everythingScopeKey)
    selectedListID = nil
    selectedFolderID = nil
    scopeTaskID = nil
    focusedBoardColumnID = nil
    taskInsertionReference = nil
    desktopShortcutSequence.reset()
    selectedTaskID = nil
    viewMode = .board
    reloadOutline(refreshSidebar: false)
  }

  /// The sidebar's Today: the day across every list, so Everything behind it.
  func selectToday() {
    // One refresh, made once the mode is Today, so Everything's board —
    // which Today does not draw — is not read on the way.
    batchingRefreshes {
      selectEverything()
      selectViewMode(.today)
    }
  }

  func selectFolder(_ folder: ListFolder) {
    // Any other way of choosing a row moves the keyboard cursor there too,
    // by letting it fall back to whatever is now selected.
    sidebarCursorID = nil
    enterFolderScope(folder)
  }

  func enterTask(_ task: WorkspaceTask) {
    taskEditor.flush()
    if isEverythingSelected {
      isEverythingSelected = false
      UserDefaults.standard.set(false, forKey: Self.everythingScopeKey)
      selectedListID = task.listId
      newTaskListID = task.listId
    }
    // Going into a task means going into the list that holds it, so a folder
    // scope ends here the same way Everything does.
    if selectedFolderID != nil {
      selectedFolderID = nil
      selectedListID = task.listId
      newTaskListID = task.listId
    }
    selectedListID = task.listId
    newTaskListID = task.listId
    selectedFolderID = nil
    scopeTaskID = task.id
    focusedBoardColumnID = nil
    viewMode = .board
    reloadOutline(refreshSidebar: false)
  }

  func selectTask(_ task: WorkspaceTask) {
    guard selectedTaskID != task.id else { return }
    taskEditor.flush()
    selectedTaskID = task.id
  }

  func selectViewMode(_ mode: WorkspaceViewMode) {
    if mode != viewMode { isDraftingTask = false }
    if mode == .today { dayPresentationCount += 1 }
    let changed = viewMode != mode
    // One refresh for both: the board a mode needs (see `viewModeDidChange`)
    // and the outline below.
    batchingRefreshes {
      viewMode = mode
      // A combined scope's outline is only gathered while the outline is
      // showing, so a change of mode may need it. Asking for the mode already
      // on screen — as launch does — cannot, and re-reading every list for
      // it was waste.
      if isMultiListScope && changed { reloadOutline(refreshSidebar: false) }
    }
  }

  func leaveTaskScope() {
    guard let task = scopeTask else { return }
    scopeTaskID = task.parentTaskId
    selectedTaskID = task.id
    reloadOutline(refreshSidebar: false)
  }
}
