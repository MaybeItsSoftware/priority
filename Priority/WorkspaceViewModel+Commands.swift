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
    if keyboardFocusArea == .done { return .done }
    if keyboardFocusArea == .sidebar { return .sidebar }
    if keyboardFocusArea == .inspector { return .inspector }
    switch viewMode {
    case .today: return .today
    case .board: return .board
    case .outline: return .outline
    case .matrix: return .matrix
    }
  }

  /// The rows the palette shows for what is typed, ordered for the surface
  /// currently on screen.
  func commandMatches(for query: String) -> [WorkspaceCommandQuery.Match] {
    WorkspaceCommandQuery.matches(
      query: query, surface: commandSurface, recents: recentCommandIDs)
  }

  // MARK: - Recently run

  private static let recentCommandsKey = "workspaceRecentCommandIDsV1"

  /// Commands run by name — from the palette, a menu or a button — most
  /// recent first. The palette ranks them higher. Read from `UserDefaults`
  /// each time rather than mirrored, because the palette asks once per
  /// keystroke and nothing else does.
  var recentCommandIDs: [WorkspaceCommandID] {
    (UserDefaults.standard.stringArray(forKey: Self.recentCommandsKey) ?? [])
      .compactMap(WorkspaceCommandID.init(rawValue:))
  }

  /// A key press is not recorded: the key is already how you reach that
  /// command, and `j` would push everything else out. Opening the palette
  /// is not either, since it is how you get to the list at all.
  private func rememberRun(_ id: WorkspaceCommandID, key: String?) {
    guard key == nil, id != .goCommandPalette, canRun(id) else { return }
    let recents = recentCommandIDs
    guard recents.first != id else { return }
    UserDefaults.standard.set(
      WorkspaceCommandQuery.recording(id, in: recents).map(\.rawValue),
      forKey: Self.recentCommandsKey)
  }

  /// Motions are listed but cannot be run — see `WorkspaceCommandKind`.
  func canRun(_ id: WorkspaceCommandID) -> Bool {
    WorkspaceCommandCatalog[id].kind == .action
  }

  // The switch is exhaustive on purpose: adding a case to `WorkspaceCommandID`
  // should not compile until someone has said what it does. That covers the
  // keyboard as well as the palette — the router has no switch of its own, so
  // a catalogue row with a key is a row whose command runs here.
  //
  // `key` is the key that asked, when one did. Motions need it to know which
  // way to move; a few actions whose keys differ in detail (Return on the
  // board, `[`) read it too. The palette passes none.
  //
  // swiftlint:disable:next cyclomatic_complexity
  func run(_ id: WorkspaceCommandID, key: String? = nil) {
    rememberRun(id, key: key)
    switch id {
    // MARK: Go
    case .goToday: goToMode(.today)
    case .goBoard: goToMode(.board)
    case .goOutline: goToMode(.outline)
    case .goMatrix: goToMode(.matrix)
    case .goEverything:
      // A place to be, like ⌘1–⌘4, so it leaves a full-pane screen the same
      // way rather than changing the list behind one.
      leaveFullPaneScreens()
      selectEverything()
      requestKeyboardFocus(.tasks)
    case .goFocus: presentFocusScreen()
    case .goTimeline:
      if showsTimelineScreen { dismissTimelineScreen() } else { presentTimelineScreen() }
    case .goListNavigator: presentOverlay(.listNavigator)
    case .goSearch: presentSearch()
    case .goCommandPalette: presentOverlay(.commandPalette)
    case .goKeyboardReference: presentOverlay(.keyboardReference)
    case .goSidebarRegion: requestKeyboardFocus(.sidebar)
    case .goTaskRegion: requestKeyboardFocus(.tasks)
    case .goInspectorRegion:
      if selectedTask == nil { selectedTaskID = visibleNavigationTasks.first?.id }
      requestKeyboardFocus(selectedTask == nil ? .tasks : .inspector)

    // MARK: Task
    case .taskNew: addTaskBelowSelection()
    case .taskNewAbove: requestRelativeTaskComposerFocus(above: true)
    case .taskNewChild: requestRelativeTaskComposerFocus(child: true)
    case .taskComplete: if viewMode == .today { tickOffSelectedDayTask() } else { toggleSelectedTask() }
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
    // Return is "open the task" on every task surface. With nothing to open
    // it adds one, so an empty list still answers to it.
    case .planEnterTask:
      if key == "enter" && selectedTask == nil { requestTaskComposerFocus() } else { enterSelectedTask() }
    case .planLeaveTask:
      // `[` only ever leaves a task. `h` and ← hand the keyboard back to the
      // sidebar once there is nothing left to leave; the bracket never did.
      if key != "[" || scopeTaskID != nil { leaveSelectedTaskScope() }
    case .planHideCompleted: toggleHiddenCompletedTasks()
    case .planBoardNewColumn: presentOverlay(.newBoardColumn)
    case .planBoardMoveCardLeft: moveSelectedTaskToAdjacentColumn(by: -1)
    case .planBoardMoveCardRight: moveSelectedTaskToAdjacentColumn(by: 1)
    case .planBoardRemoveColumn:
      // The card you are on names the column, the way ⌥← and ⌥→ do. There is
      // no separate "current column" to consult, and inventing one so a key
      // could delete something would be worse than asking for a selection.
      if boardColumns.count > 1, let task = selectedTask, let column = column(for: task) {
        removeKanbanColumn(column)
      }

    // MARK: Lists and folders
    case .listNew: requestListCreationForSelection()
    case .listRename:
      // The rename happens in the sidebar row, so it has to be on screen.
      if !isListsPaneVisible { showLeftDock(.lists) }
      beginRenamingSelection()
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
    case .windowToggleSidebar: toggleSidebar()
    case .windowToggleAgentPanel: toggleAgentPanel()
    case .windowToggleInspectorPane: toggleInspector()
    case .windowOpenKeymap: WorkspaceKeymapStore.shared.openFile()
    case .windowReloadKeymap: WorkspaceKeymapStore.shared.reload(force: true)
    case .windowShowDiagnostics: onShowDiagnostics?()
    case .windowOpenThemesFolder: UserThemeLibrary.shared.openFolder()
    case .windowReloadThemes: UserThemeLibrary.shared.reload(force: true)
    case .windowExportTheme: UserThemeLibrary.shared.exportCurrentTheme()

    // MARK: Focus
    case .focusLadderUp: moveFocusLadder(by: 1)
    case .focusLadderDown: moveFocusLadder(by: -1)
    // One key stages and then begins, so the row stands for both.
    case .focusStage: if stagedTaskID == nil { stageFocusLadderSelection() } else { beginStagedFocus() }
    case .focusBegin: beginStagedFocus()
    case .focusTickOff: focusCompletionRequest += 1
    case .focusDefer: deferFocusLadderSelection()
    case .focusPause: toggleFocusPause()
    case .focusLogAndKeep: requestFocusCompletion(completeTask: false)
    case .focusFloat: requestFocusFloat()
    case .focusFinish: requestFocusCompletion()
    case .focusResetOrder: clearManualFocusOrder()
    case .focusLeave: dismissFocusScreen()
    case .focusUnstage: if stagedTaskID != nil { unstageFocusTask() } else { dismissFocusScreen() }

    // MARK: Timeline
    case .timelinePreviousDay: moveTimelineDay(by: -1)
    case .timelineNextDay: moveTimelineDay(by: 1)
    case .timelineToday: showTimelineToday()
    case .timelineClose: dismissTimelineScreen()

    // MARK: Done rail
    case .windowToggleDoneRail: toggleDoneRail()
    case .doneReveal: if let task = doneCursorTask { revealDoneTask(task) }
    case .doneReopen: if let task = doneCursorTask { reopenDoneTask(task) }
    case .doneClose: leaveDoneRail()

    // MARK: Motions
    //
    // Listed in the palette so the reference is complete, but not runnable
    // from it: each one means "move from where the cursor is", and opening the
    // palette is precisely the act of taking the cursor somewhere else. From
    // the keyboard they arrive with the key, which says which way to go.
    case .goCycleRegion:
      if let key { cycleKeyboardFocus(by: key.contains("shift") ? -1 : 1) }
    case .planMatrixPlace: if let key { placeSelectionInQuadrant(key) }
    case .listNewTaskDestination:
      if let key { cycleNewTaskDestination(by: key.hasSuffix("[") ? -1 : 1) }
    // Same sign as the cursor keys, so the task travels the way the arrow
    // points: up the screen is up the ladder, which is *less* important.
    case .focusReorder: if let key { reorderFocusLadder(by: key.hasSuffix("up") ? 1 : -1) }
    case .motionSelectNext: if key != nil { moveTaskSelection(by: 1) }
    case .motionSelectPrevious: if key != nil { moveTaskSelection(by: -1) }
    case .motionSelectEnds: if let key { selectTaskAtEnd(first: key == "home") }
    case .motionSelectPage: if let key { moveTaskSelection(by: key == "pageup" ? -8 : 8) }
    case .motionSidebarSelect: if let key { moveSidebarCursor(key) }
    case .motionSidebarExpand: if let key { activateSidebarCursor(expandOnly: key == "right") }
    case .motionSidebarCollapse: if key != nil { collapseSidebarCursor() }
    case .motionBoardColumn: if let key { focusAdjacentBoardColumn(by: key == "right" ? 1 : -1) }
    case .motionDismiss: if key != nil { dismissFromKeyboard() }
    case .motionSetPriority:
      if let key, let digit = Int(key) { editTaskValues { $0.priority = digit } }
    case .motionDoneSelect: if let key { moveDoneCursor(key) }
    case .todayStart: startSelectedDayTask()
    case .motionTodayLeave: if key != nil { returnToCurrentListInSidebar() }
    }
  }

  // MARK: - Helpers the palette needs that the router expressed inline

  /// Asking for a mode is also asking to leave whatever full-pane surface is
  /// up — the same reasoning as ⌘1 on the timeline meaning "show me today".
  private func goToMode(_ mode: WorkspaceViewMode) {
    leaveFullPaneScreens()
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
