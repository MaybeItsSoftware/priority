package uk.co.maybeitsadam.takt.ui.commands

import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.isAltPressed
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isMetaPressed
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key

/**
 * A Kotlin copy of the keys in `Sources/TaktCore/WorkspaceCommandCatalog+Entries.swift`,
 * translated for a hardware keyboard on Android: the Mac's Cmd becomes Ctrl,
 * Option becomes Alt. Ids match the Swift `WorkspaceCommandID` cases, so the
 * two catalogues can be compared row for row.
 */
enum class KeyCommand(val id: String, val title: String, val group: String, val keys: String) {
    GO_TODAY("goToday", "Go to Today", "Go", "Ctrl+1"),
    GO_BOARD("goBoard", "Go to Board", "Go", "Ctrl+2"),
    GO_OUTLINE("goOutline", "Go to Outline", "Go", "Ctrl+3"),
    GO_MATRIX("goMatrix", "Go to Matrix", "Go", "Ctrl+4"),
    GO_EVERYTHING("goEverything", "Open Everything", "Go", "Ctrl+0"),
    GO_FOCUS("goFocus", "Enter focus mode", "Go", "Ctrl+8"),
    GO_TIMELINE("goTimeline", "Show the day's timeline", "Go", "Ctrl+9"),
    GO_SEARCH("goSearch", "Search every task", "Go", "Ctrl+F"),
    GO_COMMAND_PALETTE("goCommandPalette", "Show the command palette", "Go", "Ctrl+K"),
    TASK_NEW("taskNew", "Add a task", "Task", "Ctrl+N"),
    TASK_NEW_ABOVE("taskNewAbove", "Add a task above", "Task", "Alt+Enter"),
    TASK_NEW_CHILD("taskNewChild", "Add a subtask", "Task", "Alt+Shift+Enter"),
    TASK_COMPLETE("taskComplete", "Complete or reopen the task", "Task", "Space"),
    TASK_INVALIDATE("taskInvalidate", "Cancel or reinstate the task", "Task", "Shift+Space"),
    TASK_DELETE("taskDelete", "Delete the task", "Task", "Delete"),
    TASK_RENAME("taskRename", "Rename the task", "Task", "F2"),
    TASK_DUE_TODAY("taskDueToday", "Due today", "Task", "Ctrl+T"),
    TASK_DUE_TOMORROW("taskDueTomorrow", "Due tomorrow", "Task", "Ctrl+Shift+T"),
    TASK_CLEAR_DUE("taskClearDue", "Clear the due date", "Task", ""),
    TASK_CLEAR_PRIORITY("taskClearPriority", "Clear the priority", "Task", "0"),
    TASK_TOGGLE_DAILY("taskToggleDaily", "Commit to this daily, or stop", "Task", "Ctrl+Shift+D"),
    TASK_HABIT("taskHabit", "Make a habit, or edit this one", "Task", "Ctrl+Shift+H"),
    TASK_TOGGLE_PLANNED_TODAY("taskTogglePlannedToday", "Plan for today, or take it off", "Task", "Alt+T"),
    TASK_START_FOCUS("taskStartFocus", "Start focus on the task", "Task", "F"),
    TASK_MOVE("taskMove", "Move the task or list", "Task", "Ctrl+Shift+M"),
    TASK_CONVERT_TO_LIST("taskConvertToList", "Convert to a list, or back", "Task", "Ctrl+Shift+L"),
    TASK_EXTRACT_BRANCH("taskExtractBranch", "Extract the branch as a list", "Task", ""),
    TASK_TOGGLE_INSPECTOR("taskToggleInspector", "Open or close the inspector", "Task", "I"),
    TASK_INDENT("taskIndent", "Indent the task", "Task", "Tab"),
    TASK_OUTDENT("taskOutdent", "Outdent the task", "Task", "Shift+Tab"),
    TASK_MOVE_UP("taskMoveUp", "Move the task up", "Task", "Alt+Up"),
    TASK_MOVE_DOWN("taskMoveDown", "Move the task down", "Task", "Alt+Down"),
    PLAN_SELECT_NEXT("planSelectNext", "Select the next task", "Plan", "J / Down"),
    PLAN_SELECT_PREVIOUS("planSelectPrevious", "Select the previous task", "Plan", "K / Up"),
    PLAN_ENTER_TASK("planEnterTask", "Open the task", "Plan", "Enter"),
    PLAN_TOGGLE_FOLD("planToggleFold", "Show or hide the task's subtasks", "Plan", "Z"),
    PLAN_FOLD_ALL("planFoldAll", "Hide every task's subtasks", "Plan", "Ctrl+Left"),
    PLAN_UNFOLD_ALL("planUnfoldAll", "Show every task's subtasks", "Plan", "Ctrl+Right"),
    PLAN_BOARD_NEW_COLUMN("planBoardNewColumn", "Add a board column", "Plan", "Ctrl+Shift+C"),
    PLAN_BOARD_MOVE_CARD_LEFT("planBoardMoveCardLeft", "Move the card a column left", "Plan", "Alt+Shift+Left"),
    PLAN_BOARD_MOVE_CARD_RIGHT("planBoardMoveCardRight", "Move the card a column right", "Plan", "Alt+Shift+Right"),
    PLAN_BOARD_REMOVE_COLUMN("planBoardRemoveColumn", "Remove this board column", "Plan", ""),
    PLAN_MATRIX_PLACE("planMatrixPlace", "Place the task in a quadrant", "Plan", "Alt+1…4"),
    LIST_NEW("listNew", "Create a list", "Lists", "Ctrl+Shift+N"),
    LIST_RENAME("listRename", "Rename the list or folder", "Lists", "Ctrl+R"),
    LIST_ARCHIVE("listArchive", "Archive the current list", "Lists", ""),
    LIST_COMPLETE("listComplete", "Complete or reopen the list", "Lists", "Ctrl+Shift+X"),
    LIST_DELETE("listDelete", "Delete the list or folder", "Lists", ""),
    FOLDER_NEW("folderNew", "Create a folder", "Lists", "Ctrl+Alt+N"),
    WINDOW_UNDO("windowUndo", "Undo", "Window", "Ctrl+Z"),
    WINDOW_REDO("windowRedo", "Redo", "Window", "Ctrl+Shift+Z"),
    WINDOW_HISTORY("windowHistory", "Show the undo history", "Window", ""),
    WINDOW_SETTINGS("windowSettings", "Open settings", "Window", "Ctrl+,"),
    ;

    /** A palette row for this command. */
    fun palette(run: () -> Unit) = PaletteCommand(id, title, group, keys, run)
}

/** A key event's chord, for matching without repeating the modifier checks everywhere. */
data class Chord(val key: Key, val ctrl: Boolean = false, val shift: Boolean = false, val alt: Boolean = false) {
    fun matches(event: KeyEvent): Boolean =
        event.key == key && (event.isCtrlPressed || event.isMetaPressed) == ctrl &&
            event.isShiftPressed == shift && event.isAltPressed == alt
}
