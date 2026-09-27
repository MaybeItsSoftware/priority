import Foundation

/// Every command the desktop workspace knows about, as a name rather than a
/// keystroke.
///
/// The point of the indirection is that a key, a palette row and a menu item
/// can all say the same word. Before it, the workspace's keys were a 600-line
/// `switch` over `NSEvent` and the reference sheet was a hand-written table of
/// seventy rows beside it — two lists of the same facts, with nothing keeping
/// them equal, which is precisely how the old settings pane came to tell people
/// that `u` was undo eight months after it stopped being.
///
/// `WorkspaceCommandCatalog.all` must carry one entry per case, and
/// `WorkspaceViewModel.run(_:)` must switch over all of them; the first is a
/// test and the second is the compiler.
public enum WorkspaceCommandID: String, CaseIterable, Sendable {
  // Go
  case goToday, goBoard, goOutline, goMatrix, goEverything, goFocus, goTimeline
  case goListNavigator, goSearch, goCommandPalette, goKeyboardReference
  case goSidebarRegion, goTaskRegion, goInspectorRegion, goCycleRegion

  // Task
  case taskNew, taskNewAbove, taskNewChild, taskComplete, taskInvalidate, taskDelete
  case taskRename, taskEditDue, taskEditNotes, taskEditTags, taskEditRecurrence
  case taskEditStart, taskEditEstimate
  case taskDueToday, taskDueTomorrow, taskClearDue, taskClearNotes, taskClearTags
  case taskClearPriority, taskToggleDaily, taskStartFocus, taskMove
  case taskConvertToList, taskPromoteList, taskExtractBranch, taskOpenLink
  case taskShowProgress, taskToggleInspector
  case taskIndent, taskOutdent, taskMoveUp, taskMoveDown

  // Plan
  case planEnterTask, planLeaveTask, planHideCompleted
  case planBoardNewColumn, planBoardMoveCardLeft, planBoardMoveCardRight
  case planBoardRemoveColumn, planMatrixPlace

  // Lists and folders
  case listNew, listRename, listSettings, listArchive, listRestore, listComplete
  case listDelete, folderNew, folderMoveUp, folderMoveDown, folderSelectPrevious
  case folderSelectNext, listMoveUp, listMoveDown, listNewTaskDestination

  // Window
  case windowUndo, windowRedo, windowToggleSidebar, windowToggleInspectorPane

  // Focus surface
  case focusLadderUp, focusLadderDown, focusStage, focusBegin, focusTickOff
  case focusDefer, focusReorder, focusPause, focusLogAndKeep, focusFloat
  case focusFinish, focusLeave, focusResetOrder

  // Timeline surface
  case timelinePreviousDay, timelineNextDay, timelineToday, timelineClose

  // Motions
  case motionSelectNext, motionSelectPrevious, motionSelectEnds, motionSelectPage
  case motionSidebarSelect, motionSidebarExpand, motionSidebarCollapse
  case motionBoardColumn, motionDismiss, motionSetPriority
}
