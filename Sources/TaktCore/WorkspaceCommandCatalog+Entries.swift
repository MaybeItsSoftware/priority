import Foundation

/// The catalogue proper: every key the desktop workspace answers to, once.
///
/// Ordering within a group is roughly most-pressed-first, because the palette
/// shows this order when nothing has been typed and the reference sheet reads
/// top to bottom.
public enum WorkspaceCommandCatalog {

  /// The shipped keys. What is in force — these with any user keymap laid
  /// over them — is `all`; see `WorkspaceKeyBindings`.
  public static let defaults: [WorkspaceCommand] =
    go + task + plan + lists + window + focus + timeline + done + motions

  public static var byID: [WorkspaceCommandID: WorkspaceCommand] { bindings.byID }

  public static subscript(id: WorkspaceCommandID) -> WorkspaceCommand {
    // Force-unwrapped deliberately: `everyCommandHasAnEntry` fails the build
    // before this can, and a catalogue with a hole in it is not a thing the
    // app should try to carry on with. A keymap changes keys, never rows.
    bindings.byID[id]!
  }

  /// The menu bar's Task menu, in sections. Every action in the Task group is
  /// in it except "Add a task", which the Workspace menu carries, and "Clear
  /// the priority", which sits under the menu's priority digits; a test holds
  /// the menu to that, so a new task command cannot be left out of it.
  public static let taskMenu: [[WorkspaceCommandID]] = [
    [.taskComplete, .taskInvalidate, .taskStartFocus, .taskDelete],
    [.taskNewAbove, .taskNewChild],
    [
      .taskRename, .taskEditDue, .taskEditStart, .taskEditEstimate, .taskEditNotes,
      .taskEditTags, .taskEditRecurrence,
    ],
    [.taskDueToday, .taskDueTomorrow, .taskClearDue, .taskClearNotes, .taskClearTags],
    [.taskIndent, .taskOutdent, .taskMoveUp, .taskMoveDown],
    [.taskMoveToPreviousList, .taskMoveToNextList, .taskMove],
    [.taskConvertToList, .taskPromoteList, .taskExtractBranch],
    [.taskTogglePlannedToday, .taskToggleDaily, .taskOpenLink, .taskShowProgress, .taskToggleInspector],
  ]

  // MARK: - Go

  private static let go: [WorkspaceCommand] = [
    .init(id: .goToday, title: "Go to Today", group: "Go", keys: ["cmd+1"]),
    .init(id: .goBoard, title: "Go to Board", group: "Go", keys: ["cmd+2"]),
    .init(id: .goOutline, title: "Go to Outline", group: "Go", keys: ["cmd+3"]),
    .init(id: .goMatrix, title: "Go to Matrix", group: "Go", keys: ["cmd+4"]),
    .init(
      id: .goEverything, title: "Open Everything", group: "Go", keys: ["cmd+0", "gh"],
      note: "Every task across all active lists"),
    .init(
      id: .goFocus, title: "Open the focus panel", group: "Go", keys: ["cmd+8"],
      note: "Pick a task and start it, or bring back the block already running"),
    .init(
      id: .goTimeline, title: "Show the day's timeline", group: "Go", keys: ["cmd+9"],
      note: "Press again to close it"),
    .init(
      id: .goListNavigator, title: "Find or create a list", group: "Go", keys: ["cmd+p", "ll"],
      note: "Zed's file finder, for lists"),
    .init(
      id: .goSearch, title: "Search every task", group: "Go", keys: ["cmd+f", "cmd+shift+f", "/"],
      note: "Titles and notes. ⇧⌘F is Zed's find in project"),
    .init(
      id: .goCommandPalette, title: "Show the command palette", group: "Go",
      keys: ["cmd+shift+p", "cmd+k"], surfaceKeys: [.sidebar: [":"]],
      note: "⇧⌘P as in Zed; ⌘K as it always was. : in the sidebar, as in Zed's vim project panel"),
    .init(
      id: .goKeyboardReference, title: "Show the keyboard reference", group: "Go",
      keys: ["cmd+/", "?"], note: "The same list this palette shows"),
    .init(
      id: .goSidebarRegion, title: "Focus the sidebar", group: "Go", keys: ["ctrl+1", "cmd+shift+e"],
      note: "⇧⌘E is Zed's focus the project panel"),
    .init(id: .goTaskRegion, title: "Focus the task surface", group: "Go", keys: ["ctrl+2"]),
    .init(id: .goInspectorRegion, title: "Focus the inspector", group: "Go", keys: ["ctrl+3"]),
    .init(
      id: .goCycleRegion, title: "Cycle between regions", group: "Go",
      keys: ["ctrl+tab", "ctrl+shift+tab"], kind: .motion),
  ]

  // MARK: - Task

  private static let task: [WorkspaceCommand] = [
    .init(
      id: .taskNew, title: "Add a task", group: "Task", keys: ["enter", "cmd+n"],
      note: "Return always adds, as in Checkvist: below the selected task in the outline and the matrix"),
    .init(
      id: .taskNewAbove, title: "Add a task above", group: "Task", keys: ["shift+enter", "option+enter"],
      note: "⇧↩ is Checkvist's"),
    .init(id: .taskNewChild, title: "Add a subtask", group: "Task", keys: ["option+shift+enter"]),
    // Space always completes, as in Checkvist; Return always adds. One
    // meaning each, on every surface, so neither has to be looked up.
    .init(
      id: .taskComplete, title: "Complete or reopen the task", group: "Task",
      keys: ["space", "x"]),
    .init(
      id: .taskInvalidate, title: "Cancel or reinstate the task", group: "Task",
      keys: ["shift+space"], note: "Cancelled, rather than done — it stopped mattering"),
    .init(
      id: .taskDelete, title: "Delete the task", group: "Task", keys: ["delete", "cmd+delete", "cmd+shift+k"],
      note: "Takes its subtasks with it. ⇧⌘K is Zed's delete line"),
    .init(id: .taskRename, title: "Rename the task", group: "Task", keys: ["ee", "f2", "cmd+ctrl+e"]),
    .init(id: .taskEditDue, title: "Edit the due date", group: "Task", keys: ["dd", "cmd+d"]),
    .init(id: .taskEditNotes, title: "Edit the notes", group: "Task", keys: ["nn", "cmd+ctrl+n"]),
    .init(id: .taskEditTags, title: "Edit the tags", group: "Task", keys: ["tt", "cmd+ctrl+t"]),
    .init(id: .taskEditRecurrence, title: "Edit how it repeats", group: "Task", keys: ["dr", "cmd+ctrl+r"]),
    .init(id: .taskEditStart, title: "Edit the start date", group: "Task", keys: ["option+s"]),
    .init(id: .taskEditEstimate, title: "Edit the time estimate", group: "Task", keys: ["option+t"]),
    .init(id: .taskDueToday, title: "Due today", group: "Task", keys: ["td", "cmd+t"]),
    .init(id: .taskDueTomorrow, title: "Due tomorrow", group: "Task", keys: ["tm", "cmd+shift+t"]),
    .init(id: .taskClearDue, title: "Clear the due date", group: "Task", keys: ["cd"]),
    .init(id: .taskClearNotes, title: "Clear the notes", group: "Task", keys: ["cn"]),
    .init(id: .taskClearTags, title: "Clear the tags", group: "Task", keys: ["ct"]),
    .init(
      id: .taskClearPriority, title: "Clear the priority", group: "Task", keys: ["0"],
      note: "0 is Checkvist's spelling"),
    .init(
      id: .taskToggleDaily, title: "Commit to this daily, or stop", group: "Task",
      keys: ["cmd+shift+d"], note: "A requirement to contribute to it every day"),
    // ⌃T rather than T: bare `t` starts `td`, `tm` and `tt`, and ⌘T is
    // already "due today", which is a date rather than a choice.
    .init(
      id: .taskTogglePlannedToday, title: "Plan for today, or take it off", group: "Task",
      keys: ["ctrl+t"],
      note: "Puts it in the day you arrange by hand. On Today, plans an overdue or dated row"),
    .init(
      id: .taskStartFocus, title: "Start focus on the task", group: "Task", keys: ["f"],
      note: "Or add it to the queue behind a running block"),
    .init(
      id: .taskMove, title: "Move the task or list", group: "Task", keys: ["mm", "cmd+shift+m"],
      note: "Including everything under it"),
    .init(
      id: .taskConvertToList, title: "Convert to a list, or back", group: "Task",
      keys: ["cmd+shift+l"]),
    .init(
      id: .taskPromoteList, title: "Promote or unpin a nested list", group: "Task",
      keys: ["cmd+option+p"]),
    .init(id: .taskExtractBranch, title: "Extract the branch as a list", group: "Task", keys: ["xx"]),
    .init(id: .taskOpenLink, title: "Open the task's first link", group: "Task", keys: ["gg", "cmd+o"]),
    .init(id: .taskShowProgress, title: "Show the task's progress", group: "Task", keys: ["pc"]),
    .init(
      id: .taskToggleInspector, title: "Open or close the inspector", group: "Task",
      keys: ["i", "sd"]),
    // The modifier says what kind of move it is. Bare arrows move the cursor
    // and ⌘ moves it far; ⌥ moves the task within its list (↑↓ among its
    // siblings, ←→ out of or into the one above, as an outliner does); ⇧⌥
    // carries it somewhere else (←→ a board column, ↑↓ another list). ⌃ is
    // left alone: macOS gives ⌃ and the arrows to Spaces and Mission Control.
    .init(
      id: .taskIndent, title: "Indent the task", group: "Task",
      keys: ["tab", "option+right", "cmd+option+right"],
      note: "Under the task above it"),
    .init(
      id: .taskOutdent, title: "Outdent the task", group: "Task",
      keys: ["shift+tab", "option+left", "cmd+option+left"]),
    // ⌥↑ and ⌥↓ are Zed's move line; ⌘↑ and ⌘↓ go to the ends, as they do
    // in an editor.
    // On Today there are no siblings to move among, so they arrange the day.
    .init(
      id: .taskMoveUp, title: "Move the task up", group: "Task", keys: ["option+up"],
      note: "On Today, earlier in the day you planned"),
    .init(
      id: .taskMoveDown, title: "Move the task down", group: "Task", keys: ["option+down"],
      note: "On Today, later in the day you planned"),
    .init(
      id: .taskMoveToPreviousList, title: "Move the task to the list above", group: "Task",
      keys: ["option+shift+up"], note: "The list above its own in the sidebar. mm picks any list"),
    .init(
      id: .taskMoveToNextList, title: "Move the task to the list below", group: "Task",
      keys: ["option+shift+down"], note: "The list below its own in the sidebar. mm picks any list"),
  ]

  // MARK: - Plan

  private static let plan: [WorkspaceCommand] = [
    .init(
      id: .planEnterTask, title: "Open the task", group: "Plan",
      keys: ["right", "shift+right", "l", "]"],
      note: "Its subtasks, as a board"),
    .init(
      id: .planLeaveTask, title: "Leave the task's subtasks", group: "Plan",
      keys: ["left", "shift+left", "h", "["],
      note: "With nothing left to leave, hands the keyboard back to the sidebar"),
    .init(id: .planHideCompleted, title: "Hide or show completed tasks", group: "Plan", keys: ["hc"]),
    // Checkvist folds a branch where it stands, so a task's subtasks can be
    // read and walked without opening the task. `za` is vim's fold toggle.
    .init(
      id: .planToggleFold, title: "Show or hide the task's subtasks", group: "Plan", keys: ["za"],
      note: "In the outline, or on the board card or row you are on"),
    .init(
      id: .planFoldAll, title: "Hide every task's subtasks", group: "Plan",
      keys: ["cmd+left"], surface: .outline),
    .init(
      id: .planUnfoldAll, title: "Show every task's subtasks", group: "Plan",
      keys: ["cmd+right"], surface: .outline),
    .init(
      id: .planBoardNewColumn, title: "Add a board column", group: "Plan",
      keys: ["cmd+shift+c"], surface: .board),
    .init(
      id: .planBoardMoveCardLeft, title: "Move the card a column left", group: "Plan",
      keys: ["option+shift+left"], surface: .board),
    .init(
      id: .planBoardMoveCardRight, title: "Move the card a column right", group: "Plan",
      keys: ["option+shift+right"], surface: .board),
    .init(
      id: .planBoardRemoveColumn, title: "Remove this board column", group: "Plan",
      keys: ["cmd+ctrl+c"], surface: .board,
      note: "The column the selected card is in. ⇧⌘⌫ still deletes the list"),
    .init(
      id: .planMatrixPlace, title: "Place the task in a quadrant", group: "Plan",
      keys: ["option+1", "option+2", "option+3", "option+4"], surface: .matrix, kind: .motion,
      note: "1 urgent and important, 2 important, 3 urgent, 4 neither"),
  ]

  // MARK: - Lists and folders

  private static let lists: [WorkspaceCommand] = [
    // The sidebar is Zed's project panel: a list is a file there and a folder
    // a directory, so ⌘N, ⌥⌘N, ⌫ and F2 act on the row, and so do the vim
    // panel's netrw keys — % new file, d new directory, ⇧D delete, ⇧R rename.
    .init(
      id: .listNew, title: "Create a list", group: "Lists", keys: ["cmd+shift+n"],
      surfaceKeys: [.sidebar: ["cmd+n", "shift+5"]],
      note: "Beside the sidebar row you are on. ⌘N and % (⇧5) in the sidebar, as Zed's new file"),
    // ⌘R from anywhere; F2 only in the sidebar, because on a task pane F2
    // renames the task.
    .init(
      id: .listRename, title: "Rename the list or folder", group: "Lists", keys: ["cmd+r"],
      surfaceKeys: [.sidebar: ["f2", "shift+r"]], note: "From a task pane, the list you are in"),
    .init(id: .listSettings, title: "Open list settings", group: "Lists", keys: ["cmd+i", "oo"]),
    .init(id: .listArchive, title: "Archive the current list", group: "Lists", keys: ["cmd+option+a"]),
    .init(
      id: .listRestore, title: "Restore the last archived list", group: "Lists",
      keys: ["cmd+shift+r"]),
    .init(
      id: .listComplete, title: "Complete or reopen the list", group: "Lists",
      keys: ["cmd+shift+x"]),
    .init(
      id: .listDelete, title: "Delete the list or folder", group: "Lists",
      keys: ["cmd+shift+delete"], surfaceKeys: [.sidebar: ["delete", "cmd+delete", "shift+d"]],
      note: "Asks first. ⌫ and ⇧D on the sidebar row, as in Zed's project panel"),
    .init(
      id: .folderNew, title: "Create a folder", group: "Lists", keys: ["cmd+option+n"],
      surfaceKeys: [.sidebar: ["d"]], note: "d in the sidebar, as in Zed's vim project panel"),
    .init(
      id: .folderCollapseAll, title: "Collapse every folder", group: "Lists",
      keys: ["cmd+left"], surface: .sidebar),
    .init(
      id: .folderExpandAll, title: "Expand every folder", group: "Lists",
      keys: ["cmd+right"], surface: .sidebar),
    .init(
      id: .folderMoveUp, title: "Move the folder up", group: "Lists",
      keys: ["cmd+option+up"], surface: .sidebar),
    .init(
      id: .folderMoveDown, title: "Move the folder down", group: "Lists",
      keys: ["cmd+option+down"], surface: .sidebar),
    .init(
      id: .folderSelectPrevious, title: "Select the previous folder", group: "Lists",
      keys: ["ctrl+option+up"], surfaceKeys: [.sidebar: ["{"]]),
    .init(
      id: .folderSelectNext, title: "Select the next folder", group: "Lists",
      keys: ["ctrl+option+down"], surfaceKeys: [.sidebar: ["}"]]),
    .init(
      id: .listMoveUp, title: "Move the sidebar row up", group: "Lists", keys: ["option+up"],
      surface: .sidebar, note: "Whatever you are on — a list, a folder, or a nested list"),
    .init(
      id: .listMoveDown, title: "Move the sidebar row down", group: "Lists", keys: ["option+down"],
      surface: .sidebar, note: "Whatever you are on — a list, a folder, or a nested list"),
    .init(
      id: .listNewTaskDestination, title: "Choose where new tasks go", group: "Lists",
      keys: ["cmd+option+[", "cmd+option+]"], kind: .motion,
      note: "In a folder, which of its lists a new task lands in"),
  ]

  // MARK: - Window

  private static let window: [WorkspaceCommand] = [
    .init(id: .windowUndo, title: "Undo", group: "Window", keys: ["cmd+z", "uu", "ctrl+z"]),
    .init(id: .windowRedo, title: "Redo", group: "Window", keys: ["cmd+shift+z", "ctrl+shift+z"]),
    .init(
      id: .windowToggleSidebar, title: "Show or hide the sidebar", group: "Window",
      keys: ["cmd+b", "cmd+ctrl+s"], note: "⌘B toggles the left dock, as in Zed"),
    .init(
      id: .windowToggleInspectorPane, title: "Show or hide the inspector", group: "Window",
      keys: ["cmd+ctrl+i", "cmd+option+b"],
      note: "Same pane as ⌘I on a task, without selecting one. ⌥⌘B is Zed's toggle right dock"),
    .init(
      id: .windowToggleDoneRail, title: "Show or hide what you have finished", group: "Window",
      keys: ["cmd+ctrl+d"],
      note: "Opens it and takes the keyboard; again from inside it closes it"),
    .init(
      id: .windowToggleAgentPanel, title: "Show or hide the agent panel", group: "Window",
      keys: ["cmd+shift+a", "cmd+ctrl+a"],
      note: "Claude Code in the left dock: reads freely, asks before every change"),
    .init(
      id: .windowToggleProgressDock, title: "Show or hide the progress graph", group: "Window",
      keys: ["cmd+j"],
      note: "The bottom dock: tasks done and added a day at a time. ⌘J toggles the bottom dock, as in Zed"),
    .init(
      id: .windowCloseAllDocks, title: "Close all docks", group: "Window",
      keys: ["cmd+option+y"], note: "The sidebar, the right dock and the progress graph, as in Zed"),
    .init(
      id: .windowOpenKeymap, title: "Open the keymap file", group: "Window", keys: [],
      note: "keymap.json — your own keys over these. Created empty if it is missing"),
    .init(
      id: .windowReloadKeymap, title: "Reload the keymap", group: "Window", keys: [],
      note: "It reloads by itself when saved; this is for when it did not"),
    .init(
      id: .windowShowDiagnostics, title: "Show diagnostics", group: "Window", keys: [],
      note: "Connection, integration health, and this session's problems"),
    .init(
      id: .windowOpenThemesFolder, title: "Open the themes folder", group: "Window", keys: [],
      note: "Each .json there is a theme in the picker. Created if it is missing"),
    .init(
      id: .windowReloadThemes, title: "Reload themes", group: "Window", keys: [],
      note: "They reload by themselves when saved; this is for when they did not"),
    .init(
      id: .windowExportTheme, title: "Export the current theme as JSON", group: "Window",
      keys: [], note: "A complete, editable copy in the themes folder, put in force"),
  ]

  // MARK: - Focus

  private static let focus: [WorkspaceCommand] = [
    .init(
      id: .focusLadderUp, title: "Climb to less important work", group: "Focus",
      keys: ["up", "k"], surface: .focus),
    .init(
      id: .focusLadderDown, title: "Back down towards the most important", group: "Focus",
      keys: ["down", "j"], surface: .focus),
    .init(
      id: .focusStage, title: "Stage the selected task", group: "Focus",
      keys: ["f"], surface: .focus,
      note: "Press again to begin the block with the estimate shown"),
    .init(
      id: .focusBegin, title: "Begin the staged block", group: "Focus", keys: [],
      surface: .focus, note: "The second f on a staged task"),
    .init(
      id: .focusTickOff, title: "Tick the task off without starting", group: "Focus",
      keys: ["space", "x"], surface: .focus),
    .init(
      id: .focusDefer, title: "Schedule it for tomorrow morning", group: "Focus", keys: ["l"],
      surface: .focus, note: "So it stops being offered"),
    .init(
      id: .focusReorder, title: "Move the task up or down the ladder", group: "Focus",
      keys: ["option+up", "option+down"], surface: .focus, kind: .motion,
      note: "Fixes your own order over the computed one"),
    .init(
      id: .focusPause, title: "Pause or resume the block", group: "Focus", keys: ["p"],
      surface: .focusRunning),
    .init(
      id: .focusLogAndKeep, title: "End the block, keep the task open", group: "Focus",
      keys: ["l"], surface: .focusRunning),
    .init(
      id: .focusFloat, title: "Send the block to the tray", group: "Focus", keys: ["f"],
      surface: .focusRunning),
    .init(
      id: .focusFinish, title: "Finish the block", group: "Focus", keys: ["space", "x"],
      surface: .focusRunning, note: "Asks how it went"),
    .init(
      id: .focusLeave, title: "Leave the focus screen", group: "Focus", keys: ["escape"],
      surface: .focusRunning, note: "The block keeps running behind it"),
    .init(
      id: .focusResetOrder, title: "Drop your own order of the ladder", group: "Focus",
      keys: ["o"], surface: .focus,
      note: "Back to the computed order, which is what the ladder is for"),
    .init(
      id: .focusUnstage, title: "Unstage the task, or leave the ladder", group: "Focus",
      keys: ["escape"], surface: .focus, note: "Unstages first when a task is staged"),
  ]

  // MARK: - Timeline

  private static let timeline: [WorkspaceCommand] = [
    .init(
      id: .timelinePreviousDay, title: "Step back a day", group: "Timeline",
      keys: ["left", "h"], surface: .timeline),
    .init(
      id: .timelineNextDay, title: "Step forward a day", group: "Timeline",
      keys: ["right", "l"], surface: .timeline),
    .init(id: .timelineToday, title: "Return to today", group: "Timeline", keys: ["t"], surface: .timeline),
    .init(
      id: .timelineClose, title: "Close the timeline", group: "Timeline", keys: ["escape"],
      surface: .timeline),
  ]

  // MARK: - Done rail

  private static let done: [WorkspaceCommand] = [
    .init(
      id: .motionDoneSelect, title: "Move through what you finished", group: "Done",
      keys: ["down", "up", "j", "k", "home", "end", "cmd+up", "cmd+down", "pageup", "pagedown"],
      surface: .done,
      kind: .motion),
    .init(
      id: .doneReveal, title: "Open it where it lives", group: "Done", keys: ["o"],
      surface: .done, note: "Leaves the rail and selects the task in its own list"),
    .init(
      id: .doneReopen, title: "Put it back on the list", group: "Done", keys: ["space", "r"],
      surface: .done),
    .init(
      id: .doneClose, title: "Leave the rail", group: "Done", keys: ["escape", "left"],
      surface: .done, note: "Left, like leaving any pane on the right: back towards the work"),
  ]

  // MARK: - Motions

  private static let motions: [WorkspaceCommand] = [
    .init(
      id: .motionSelectNext, title: "Select the next task", group: "Moving around",
      keys: ["down", "j"], kind: .motion),
    .init(
      id: .motionSelectPrevious, title: "Select the previous task", group: "Moving around",
      keys: ["up", "k"], kind: .motion),
    .init(
      id: .motionSelectEnds, title: "Jump to the first or last task", group: "Moving around",
      keys: ["home", "end", "cmd+up", "cmd+down"], kind: .motion),
    .init(
      id: .motionSelectPage, title: "Move eight tasks at a time", group: "Moving around",
      keys: ["pageup", "pagedown"], kind: .motion),
    .init(
      id: .motionSidebarSelect, title: "Move through the sidebar", group: "Moving around",
      keys: [
        "down", "up", "j", "k", "home", "end", "cmd+up", "cmd+down", "gg", "shift+g", "pageup",
        "pagedown",
      ],
      surface: .sidebar,
      kind: .motion,
      note: "Every row, including Focus and the timeline; Home and End, or gg and ⇧G, are the two ends"),
    .init(
      id: .motionSidebarExpand, title: "Open the row you are on",
      group: "Moving around", keys: ["right", "l"], surface: .sidebar,
      kind: .motion,
      note: "Focus and the timeline open their screens, a folder expands, a list takes the keyboard"),
    .init(
      id: .motionSidebarCollapse, title: "Collapse the folder, or go up a level",
      group: "Moving around", keys: ["left", "h", "-"], surface: .sidebar, kind: .motion,
      note: "Nothing to leave on Focus or the timeline, so it stays put. - is Zed's select parent"),
    .init(
      id: .motionBoardColumn, title: "Focus the next or previous column",
      group: "Moving around", keys: ["left", "right"], surface: .board, kind: .motion),
    .init(
      id: .motionOutlineUnfold, title: "Show the subtasks, or step into them",
      group: "Moving around", keys: ["right"], surface: .outline, kind: .motion,
      note: "l or ] still opens the task"),
    .init(
      id: .motionOutlineFold, title: "Hide the subtasks, or step out to the parent",
      group: "Moving around", keys: ["left"], surface: .outline, kind: .motion,
      note: "At the top level it leaves, as ← does elsewhere"),
    .init(
      id: .motionDismiss, title: "Clear the selection, or leave the scope",
      group: "Moving around", keys: ["escape"], kind: .motion),
    .init(
      id: .motionSetPriority, title: "Set the task's priority", group: "Moving around",
      keys: ["1", "2", "3", "4", "5", "6", "7", "8", "9"], kind: .motion,
      note: "Type the digit; 0 clears it"),
    // Today's list is walked with the ordinary selection keys, the way every
    // other pane's is — it used to keep a selection of its own behind a search
    // field, and these keys only handed that field the caret back. What is
    // left of its own is f, which queues behind a running block rather than
    // replacing it, and ←, which has no hierarchy to leave and so goes to the
    // sidebar.
    .init(
      id: .todayStart, title: "Start the task, or finish the running one", group: "Today",
      keys: ["f"], surface: .today,
      note: "Or add it to the queue behind a running block"),
    .init(
      id: .motionTodayLeave, title: "Back to the sidebar", group: "Moving around",
      keys: ["left"], surface: .today, kind: .motion),
  ]
}
