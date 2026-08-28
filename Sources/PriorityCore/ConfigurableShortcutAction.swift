import Foundation

public enum ConfigurableShortcutAction: String, CaseIterable, Identifiable, Sendable {
  case openCommandPalette
  case rootCycleTabPrevious
  case rootCycleTabNext
  case rootCycleFilterPrevious
  case rootCycleFilterNext
  case moveTaskUp
  case moveTaskDown
  case openInObsidian
  case openInObsidianNewWindow
  case nextTask
  case previousTask
  /// Right / left on a row. These open and shut the row in place; the scope
  /// changing pair is `zoomIntoTask` / `zoomOutOfTask`. The raw values are kept
  /// as they were so custom bindings survive the change.
  case enterChildren
  case exitToParent
  case zoomIntoTask
  case zoomOutOfTask
  case markDone
  case invalidateTask
  case addSibling
  case addChild
  case unindentTask
  case closeOrCancel
  case editTaskAtEnd
  case editTaskAtStart
  case deleteTask
  case rootTabAll
  case rootTabDue
  case rootTabTags
  case rootTabPriority
  case rootFilter1
  case rootFilter2
  case rootFilter3
  case rootFilter4
  case rootFilter5
  case rootFilter6
  case rootFilter7
  case sequenceDue
  case sequenceDueToday
  case sequenceStart
  case sequenceRepeat
  case sequenceOpenLink
  case sequenceGoogleCalendar
  case sequenceTag
  case sequenceUntag
  case sequenceToggleContext
  case toggleTimer
  case toggleTimerPause
  case undo
  case toggleHideFuture
  case quickListSwitch
  case quickAdd
  case focusSearch
  case clearPriority
  case clearAbsolutePriority
  case pushPriorityBack
  case setPriorityRank
  case setAbsolutePriorityRank
  case kanbanMoveLeft
  case kanbanMoveRight
  case kanbanFocusLeft
  case kanbanFocusRight
  case rootTabKanban
  case kanbanShowInAll
  case kanbanEnterTaskChildren
  case kanbanExitToTaskParent
  case kanbanFocusMode
  case rootTabMatrix
  case sequenceUrgency
  case sequenceImportance
  case sequenceMatrixCoord
  /// Shows or hides the Matrix view's list of what has no coordinate yet.
  /// Spelled as an `m` sequence because that is where you already look for the
  /// matrix's vocabulary, and the pending-`m` hint can then teach it.
  case matrixToggleUnplaced
  case copyTask
  case indentTask
  case rootTabDaily
  /// Checkvist's `Alt+Enter`. The counterpart to `addSibling`, which only ever
  /// inserted below.
  case addSiblingAbove
  /// Checkvist's `Ctrl+D`, spelled `Cmd+D` because this is a Mac.
  case duplicateTask
  /// Checkvist's `?`. Opens the keyboard reference.
  case showShortcutReference

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .openCommandPalette: return "Open command palette"
    case .rootCycleTabPrevious: return "Cycle root tab previous"
    case .rootCycleTabNext: return "Cycle root tab next"
    case .rootCycleFilterPrevious: return "Cycle root filter previous"
    case .rootCycleFilterNext: return "Cycle root filter next"
    case .moveTaskUp: return "Move task up"
    case .moveTaskDown: return "Move task down"
    case .openInObsidian: return "Open in Obsidian"
    case .openInObsidianNewWindow: return "Open in new Obsidian window"
    case .nextTask: return "Next task"
    case .previousTask: return "Previous task"
    case .enterChildren: return "Expand / step into subtasks"
    case .exitToParent: return "Collapse / step out to parent"
    case .zoomIntoTask: return "Zoom into selected task"
    case .zoomOutOfTask: return "Zoom out to parent scope"
    case .markDone: return "Mark done"
    case .invalidateTask: return "Invalidate task"
    case .addSibling: return "Add sibling"
    case .addChild: return "Add child"
    case .unindentTask: return "Unindent task"
    case .closeOrCancel: return "Close/cancel"
    case .editTaskAtEnd: return "Edit task (end)"
    case .editTaskAtStart: return "Edit task (start)"
    case .deleteTask: return "Delete task"
    case .rootTabAll: return "Jump to root tab: All"
    case .rootTabDue: return "Jump to root tab: Due"
    case .rootTabTags: return "Jump to root tab: Tags"
    case .rootTabPriority: return "Jump to root tab: Priority"
    case .rootFilter1: return "Root filter slot 1"
    case .rootFilter2: return "Root filter slot 2"
    case .rootFilter3: return "Root filter slot 3"
    case .rootFilter4: return "Root filter slot 4"
    case .rootFilter5: return "Root filter slot 5"
    case .rootFilter6: return "Root filter slot 6"
    case .rootFilter7: return "Root filter slot 7"
    case .sequenceDue: return "Sequence: due"
    case .sequenceDueToday: return "Sequence: due today"
    case .sequenceStart: return "Sequence: start date"
    case .sequenceRepeat: return "Sequence: repeat"
    case .sequenceOpenLink: return "Sequence: open link"
    case .sequenceGoogleCalendar: return "Sequence: Google Calendar"
    case .sequenceTag: return "Sequence: tag"
    case .sequenceUntag: return "Sequence: untag"
    case .sequenceToggleContext: return "Sequence: toggle context"
    case .toggleTimer: return "Toggle timer"
    case .toggleTimerPause: return "Pause/resume timer"
    case .undo: return "Undo"
    case .toggleHideFuture: return "Toggle hide future"
    case .quickListSwitch: return "Quick list switch"
    case .quickAdd: return "Quick add"
    case .focusSearch: return "/"
    // `0` is Checkvist's "remove priority colours". `-` predates it here and
    // stays, because a binding someone already has in their fingers is not
    // worth taking away to make a table tidier.
    case .clearPriority: return "-,0"
    case .clearAbsolutePriority: return "Clear absolute priority"
    case .pushPriorityBack: return "Send priority to back"
    case .setPriorityRank: return "Set priority rank"
    case .setAbsolutePriorityRank: return "Set absolute priority rank"
    case .kanbanMoveLeft: return "Kanban: move task to previous column"
    case .kanbanMoveRight: return "Kanban: move task to next column"
    case .kanbanFocusLeft: return "Kanban: focus previous column"
    case .kanbanFocusRight: return "Kanban: focus next column"
    case .rootTabKanban: return "Jump to root tab: Kanban"
    case .kanbanShowInAll: return "Kanban: show task in All view"
    case .kanbanEnterTaskChildren: return "Kanban: drill into selected task's subtasks"
    case .kanbanExitToTaskParent: return "Kanban: pop up to parent scope"
    case .kanbanFocusMode: return "Focus selected task"
    case .rootTabMatrix: return "Jump to root tab: Matrix"
    case .sequenceUrgency: return "Sequence: urgency"
    case .sequenceImportance: return "Sequence: importance"
    case .sequenceMatrixCoord: return "Sequence: matrix coordinates"
    case .matrixToggleUnplaced: return "Matrix: show or hide what's unplaced"
    case .copyTask: return "Copy task to clipboard"
    case .indentTask: return "Indent task"
    case .rootTabDaily: return "Jump to root tab: Daily"
    case .addSiblingAbove: return "Add sibling above"
    case .duplicateTask: return "Duplicate task"
    case .showShortcutReference: return "Show keyboard shortcuts"
    }
  }

  public var category: String {
    switch self {
    case .nextTask, .previousTask, .enterChildren, .exitToParent, .zoomIntoTask, .zoomOutOfTask,
      .rootCycleTabPrevious,
      .rootCycleTabNext, .rootCycleFilterPrevious, .rootCycleFilterNext, .rootTabAll, .rootTabDue,
      .rootTabTags, .rootTabPriority, .rootFilter1, .rootFilter2, .rootFilter3, .rootFilter4,
      .rootFilter5, .rootFilter6, .rootFilter7, .rootTabKanban,
      .kanbanFocusLeft, .kanbanFocusRight, .kanbanShowInAll,
      .kanbanEnterTaskChildren, .kanbanExitToTaskParent, .kanbanFocusMode, .rootTabMatrix,
      .matrixToggleUnplaced, .rootTabDaily:
      return "Navigation"
    case .markDone, .invalidateTask, .addSibling, .addChild, .unindentTask, .editTaskAtEnd,
      .editTaskAtStart, .deleteTask, .moveTaskUp, .moveTaskDown, .undo, .clearPriority,
      .clearAbsolutePriority, .pushPriorityBack, .setPriorityRank, .setAbsolutePriorityRank,
      .kanbanMoveLeft, .kanbanMoveRight, .copyTask, .indentTask, .addSiblingAbove,
      .duplicateTask:
      return "Task Actions"
    case .openCommandPalette, .closeOrCancel, .focusSearch, .sequenceDue, .sequenceDueToday,
      .sequenceStart, .sequenceRepeat, .sequenceTag, .sequenceUntag, .sequenceToggleContext,
      .quickListSwitch, .quickAdd, .sequenceUrgency, .sequenceImportance, .sequenceMatrixCoord,
      .showShortcutReference:
      return "Entry & Commands"
    case .openInObsidian, .openInObsidianNewWindow, .sequenceOpenLink, .sequenceGoogleCalendar,
      .toggleTimer, .toggleTimerPause, .toggleHideFuture:
      return "Integrations & Timer"
    }
  }

  /// Whether this action is bound to a two-key sequence (`dd`, `gc`, `mu`)
  /// rather than to a single chord.
  ///
  /// The distinction matters because the two are matched differently —
  /// `PreferencesManager.shortcutMatchesSequence` against an accumulated key
  /// buffer, versus `shortcutMatches` against one `ShortcutKeyToken`. A
  /// sequence binding is *not* a producible key token and must never be checked
  /// as though it were. `KeyboardShortcutRouter` used to carry its own
  /// hand-written list of these; this is now the one definition.
  public var isTwoKeySequence: Bool {
    switch self {
    case .sequenceDue, .sequenceDueToday, .sequenceStart, .sequenceRepeat, .sequenceOpenLink,
      .sequenceGoogleCalendar, .sequenceTag, .sequenceUntag, .sequenceToggleContext,
      .sequenceUrgency, .sequenceImportance, .sequenceMatrixCoord, .matrixToggleUnplaced:
      return true
    default:
      return false
    }
  }

  /// Every two-key-sequence action, in the order the router tries them.
  public static let twoKeySequenceActions: [ConfigurableShortcutAction] =
    allCases.filter(\.isTwoKeySequence)

  public var defaultBinding: String {
    switch self {
    case .openCommandPalette: return "cmd+k,;,shift+;"
    case .rootCycleTabPrevious: return "ctrl+left"
    case .rootCycleTabNext: return "ctrl+right"
    case .rootCycleFilterPrevious: return "ctrl+up"
    case .rootCycleFilterNext: return "ctrl+down"
    case .moveTaskUp: return "cmd+up,cmd+k"
    case .moveTaskDown: return "cmd+down,cmd+j"
    case .openInObsidian: return "o"
    case .openInObsidianNewWindow: return "shift+o"
    case .nextTask: return "down,j"
    case .previousTask: return "up,k"
    case .enterChildren: return "right,l"
    case .exitToParent: return "left,h"
    case .zoomIntoTask: return "shift+right"
    case .zoomOutOfTask: return "shift+left"
    case .markDone: return "space"
    case .invalidateTask: return "shift+space"
    case .addSibling: return "enter"
    // `tab` used to be here as well. It moved to `indentTask`, which is what
    // Checkvist binds it to and what this app's own `shift+tab` already
    // implied: unindent had a bare-Tab counterpart that indented nothing.
    case .addChild: return "shift+enter"
    case .unindentTask: return "cmd+left,shift+tab"
    case .closeOrCancel: return "escape"
    case .editTaskAtEnd: return "f2,a"
    case .editTaskAtStart: return "i"
    case .deleteTask: return "delete"
    case .rootTabAll: return "q"
    case .rootTabDue: return "w"
    case .rootTabTags: return "e"
    case .rootTabPriority: return "r"
    case .rootFilter1: return "z"
    case .rootFilter2: return "x"
    case .rootFilter3: return "c"
    case .rootFilter4: return "v"
    case .rootFilter5: return "b"
    case .rootFilter6: return "n"
    case .rootFilter7: return "comma"
    case .sequenceDue: return "dd"
    case .sequenceDueToday: return "dt"
    case .sequenceStart: return "ds"
    case .sequenceRepeat: return "dr"
    case .sequenceOpenLink: return "gg"
    case .sequenceGoogleCalendar: return "gc"
    case .sequenceTag: return "gt"
    case .sequenceUntag: return "gu"
    case .sequenceToggleContext: return "sc"
    case .toggleTimer: return "p"
    case .toggleTimerPause: return "shift+p"
    case .undo: return "cmd+z"
    case .toggleHideFuture: return "shift+h"
    case .quickListSwitch: return "shift+l"
    case .quickAdd: return "shift+a"
    case .focusSearch: return "/"
    // `0` is Checkvist's "remove priority colours". `-` predates it here and
    // stays, because a binding someone already has in their fingers is not
    // worth taking away to make a table tidier.
    case .clearPriority: return "-,0"
    case .clearAbsolutePriority: return "ctrl+cmd+option+shift+-"
    case .pushPriorityBack: return "="
    case .setPriorityRank: return "1,2,3,4,5,6,7,8,9"
    case .setAbsolutePriorityRank:
      return "ctrl+cmd+option+shift+1,ctrl+cmd+option+shift+2,ctrl+cmd+option+shift+3,"
        + "ctrl+cmd+option+shift+4,ctrl+cmd+option+shift+5,ctrl+cmd+option+shift+6,"
        + "ctrl+cmd+option+shift+7,ctrl+cmd+option+shift+8,ctrl+cmd+option+shift+9"
    case .kanbanMoveLeft: return "cmd+left"
    case .kanbanMoveRight: return "cmd+right"
    case .kanbanFocusLeft: return "left,h"
    case .kanbanFocusRight: return "right,l"
    case .rootTabKanban: return "t"
    case .kanbanShowInAll: return "f"
    case .kanbanEnterTaskChildren: return "]"
    case .kanbanExitToTaskParent: return "["
    case .kanbanFocusMode: return "'"
    case .rootTabMatrix: return "y"
    case .sequenceUrgency: return "mu"
    case .sequenceImportance: return "mi"
    case .sequenceMatrixCoord: return "mm"
    case .matrixToggleUnplaced: return "ml"
    case .copyTask: return "cmd+c"
    case .indentTask: return "cmd+right,tab"
    // `u` continues the `q w e r t y` row the other root tabs sit on, so the
    // tabs stay one unbroken run of keys. It cost undo its unmodified letter;
    // undo took `cmd+z` instead, which is where the rest of macOS puts it.
    case .rootTabDaily: return "u"
    case .addSiblingAbove: return "option+enter"
    case .duplicateTask: return "cmd+d"
    // Checkvist opens its shortcut help on `?`, and so does this. Spelled
    // `shift+/` because that is what `ShortcutKeyToken` produces — the token is
    // built from `charactersIgnoringModifiers`, which reports `/`.
    case .showShortcutReference: return "shift+/"
    }
  }
}
