import AppKit
import Foundation
import PriorityCore
import PriorityWorkspace

/// Running a command by name.
///
/// The key router in `WorkspaceViewModel+Keyboard.swift` decides *which*
/// command a keystroke means; this decides what the command does. Splitting
/// those apart is what lets the palette exist at all — before it, every action
/// the workspace had was reachable only by pressing exactly the right key in
/// exactly the right pane, and the only written record of them was a table
/// beside the router that nothing kept honest.
@MainActor
extension WorkspaceViewModel {

  /// What is in the main pane, as the catalogue names it. Drives which rows
  /// the palette puts at the top and which keys the reference calls current.
  var commandSurface: WorkspaceCommandSurface {
    if showsTimelineScreen { return .timeline }
    if showsFocusScreen {
      return activeFocusSession != nil && activeFocusTask != nil ? .focusRunning : .focus
    }
    if keyboardFocusArea == .sidebar { return .sidebar }
    if keyboardFocusArea == .inspector { return .inspector }
    switch viewMode {
    case .today: return .today
    case .board: return .board
    case .outline: return .outline
    case .matrix: return .matrix
    case .focus: return .focus
    }
  }

  /// The rows the palette shows for what is typed, ordered for the surface
  /// currently on screen.
  func commandMatches(for query: String) -> [WorkspaceCommandQuery.Match] {
    WorkspaceCommandQuery.matches(query: query, surface: commandSurface)
  }

  /// Motions are listed but cannot be run — see `WorkspaceCommandKind`.
  func canRun(_ id: WorkspaceCommandID) -> Bool {
    WorkspaceCommandCatalog[id].kind == .action
  }

  // The switch is exhaustive on purpose: adding a case to `WorkspaceCommandID`
  // should not compile until someone has said what it does.
  //
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  func run(_ id: WorkspaceCommandID) {
    switch id {
    // MARK: Go
    case .goToday: goToMode(.today)
    case .goBoard: goToMode(.board)
    case .goOutline: goToMode(.outline)
    case .goMatrix: goToMode(.matrix)
    case .goEverything: selectEverything(); requestKeyboardFocus(.tasks)
    case .goFocus: presentFocusScreen()
    case .goTimeline:
      if showsTimelineScreen { dismissTimelineScreen() } else { presentTimelineScreen() }
    case .goListNavigator: showsListNavigator = true
    case .goSearch: presentSearch()
    case .goCommandPalette: showsCommandPalette = true
    case .goKeyboardReference: showsKeyboardHelp = true
    case .goSidebarRegion: requestKeyboardFocus(.sidebar)
    case .goTaskRegion: requestKeyboardFocus(.tasks)
    case .goInspectorRegion:
      if selectedTask == nil { selectedTaskID = visibleNavigationTasks.first?.id }
      requestKeyboardFocus(selectedTask == nil ? .tasks : .inspector)

    // MARK: Task
    case .taskNew: requestTaskComposerFocus()
    case .taskNewAbove: requestRelativeTaskComposerFocus(above: true)
    case .taskNewChild: requestRelativeTaskComposerFocus(child: true)
    case .taskComplete: toggleSelectedTask()
    case .taskInvalidate: if let task = selectedTask { invalidateTask(task) }
    case .taskDelete: deleteSelectedTask()
    case .taskRename: editSelectedTaskTitle()
    case .taskEditDue: quickEdit(.due)
    case .taskEditNotes: quickEdit(.notes)
    case .taskEditTags: quickEdit(.tags)
    case .taskEditRecurrence: quickEdit(.recurrence)
    case .taskEditStart: quickEdit(.start)
    case .taskEditEstimate: quickEdit(.estimate)
    case .taskDueToday: setDue(daysFromToday: 0)
    case .taskDueTomorrow: setDue(daysFromToday: 1)
    case .taskClearDue: editTaskValues { $0.dueAt = nil; $0.dueDate = nil }
    case .taskClearNotes: editTaskValues { $0.notes = "" }
    case .taskClearTags: editTaskValues { $0.tags = "" }
    case .taskClearPriority: editTaskValues { $0.priority = 0 }
    case .taskToggleDaily:
      if let task = selectedTask { setDailyProgressTask(task, enabled: !isDailyProgressTask(task)) }
    case .taskStartFocus: focusSelectedTask()
    case .taskMove: requestMoveSelectedTask()
    case .taskConvertToList: convertSelectionToList()
    case .taskPromoteList: if let task = sidebarOrSelectedTask { toggleListPromotion(task) }
    case .taskExtractBranch: if let task = selectedTask { moveDroppedItem(task.id, toFolderID: nil) }
    case .taskOpenLink: openFirstLinkOnSelection()
    case .taskShowProgress: if selectedTask != nil { requestKeyboardFocus(.inspector) }
    case .taskToggleInspector: toggleInspector()
    case .taskIndent: if let task = selectedTask { indentTask(task) }
    case .taskOutdent: if let task = selectedTask { outdentTask(task) }
    case .taskMoveUp: moveSelectionWithinSiblings(by: -1)
    case .taskMoveDown: moveSelectionWithinSiblings(by: 1)

    // MARK: Plan
    case .planEnterTask: enterSelectedTask()
    case .planLeaveTask: leaveSelectedTaskScope()
    case .planHideCompleted: toggleHiddenCompletedTasks()
    case .planBoardNewColumn: newKanbanColumnRequest = true
    case .planBoardMoveCardLeft: moveSelectedTaskToAdjacentColumn(by: -1)
    case .planBoardMoveCardRight: moveSelectedTaskToAdjacentColumn(by: 1)

    // MARK: Lists and folders
    case .listNew: requestListCreationForSelection()
    case .listRename: beginRenamingSelection()
    case .listSettings: showSelectedListSettings()
    case .listArchive: archiveSelectedList()
    case .listRestore: restoreMostRecentlyArchivedList()
    case .listComplete: toggleCurrentListCompletion()
    case .listDelete: requestDeletionOfSelectedSidebarItem()
    case .folderNew: requestFolderCreationForSelection()
    case .folderMoveUp: if let folder = selectedFolder { moveFolderWithinSiblings(folder, by: -1) }
    case .folderMoveDown: if let folder = selectedFolder { moveFolderWithinSiblings(folder, by: 1) }
    case .folderSelectPrevious: moveFolderSelection(by: -1)
    case .folderSelectNext: moveFolderSelection(by: 1)
    case .listMoveUp: reorderSidebarCursor(by: -1)
    case .listMoveDown: reorderSidebarCursor(by: 1)

    // MARK: Window
    case .windowUndo: undoLastChange()
    case .windowRedo: redoLastUndoneChange()

    // MARK: Focus
    case .focusLadderUp: moveFocusLadder(by: 1)
    case .focusLadderDown: moveFocusLadder(by: -1)
    case .focusStage: stageFocusLadderSelection()
    case .focusBegin: beginStagedFocus()
    case .focusTickOff: focusCompletionRequest += 1
    case .focusDefer: deferFocusLadderSelection()
    case .focusPause: toggleFocusPause()
    case .focusLogAndKeep: requestFocusCompletion(completeTask: false)
    case .focusFloat: requestFocusFloat()
    case .focusFinish: requestFocusCompletion()
    case .focusLeave: dismissFocusScreen()

    // MARK: Timeline
    case .timelinePreviousDay: moveTimelineDay(by: -1)
    case .timelineNextDay: moveTimelineDay(by: 1)
    case .timelineToday: showTimelineToday()
    case .timelineClose: dismissTimelineScreen()

    // MARK: Motions
    //
    // Listed in the palette so the reference is complete, but not runnable
    // from it: each one means "move from where the cursor is", and opening the
    // palette is precisely the act of taking the cursor somewhere else.
    case .goCycleRegion, .planMatrixPlace, .listNewTaskDestination,
      .focusReorder, .motionSelectNext, .motionSelectPrevious, .motionSelectEnds,
      .motionSelectPage, .motionSidebarSelect, .motionSidebarExpand,
      .motionSidebarCollapse, .motionBoardColumn, .motionDismiss, .motionSetPriority:
      break
    }
  }

  // MARK: - Helpers the palette needs that the router expressed inline

  /// Asking for a mode is also asking to leave whatever full-pane surface is
  /// up — the same reasoning as ⌘1 on the timeline meaning "show me today".
  private func goToMode(_ mode: WorkspaceViewMode) {
    dismissFocusScreen()
    dismissTimelineScreen()
    selectViewMode(mode)
    requestKeyboardFocus(.tasks)
  }

  private func setDue(daysFromToday days: Int) {
    let start = Calendar.current.startOfDay(for: .now)
    let day = Calendar.current.date(byAdding: .day, value: days, to: start)
    editTaskValues { $0.dueAt = day; $0.dueDate = nil }
  }

  /// The sidebar acts on the list it is standing in; the task panes act on the
  /// selected task. Both fall back to the scope, which is the task a nested
  /// list is really made of.
  private var sidebarOrSelectedTask: WorkspaceTask? {
    keyboardFocusArea == .sidebar ? scopeTask : selectedTask ?? scopeTask
  }

  private func convertSelectionToList() {
    if let task = sidebarOrSelectedTask {
      convertItem(task)
    } else if let list = selectedList, !list.isSystemList {
      convertListToTask(list)
    }
  }

  private func moveSelectionWithinSiblings(by offset: Int) {
    if keyboardFocusArea == .sidebar {
      reorderSidebarCursor(by: offset)
    } else if let task = selectedTask {
      moveTaskWithinSiblings(task, by: offset)
    }
  }

  private func toggleHiddenCompletedTasks() {
    hidesCompletedTasks.toggle()
    reloadOutline()
    if let selectedTaskID, !visibleNavigationTasks.contains(where: { $0.id == selectedTaskID }) {
      self.selectedTaskID = nil
    }
  }

  private func openFirstLinkOnSelection() {
    guard let task = selectedTask, let store,
      let snapshot = try? store.taskEditorSnapshot(for: task.id),
      let link = snapshot.metadata.externalLinks.first, let url = URL(string: link),
      ["https", "http", "obsidian"].contains(url.scheme?.lowercased() ?? "")
    else { return }
    NSWorkspace.shared.open(url)
  }
}
