package uk.co.maybeitsadam.priority.ui.lists

import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.type
import uk.co.maybeitsadam.priority.app.AppContainer
import uk.co.maybeitsadam.priority.core.TaskStatus
import uk.co.maybeitsadam.priority.ui.commands.Chord
import uk.co.maybeitsadam.priority.ui.commands.KeyCommand
import uk.co.maybeitsadam.priority.ui.commands.PaletteCommand
import uk.co.maybeitsadam.priority.ui.theme.PIcons

/** The dialogs and sheets a list screen can show. */
sealed interface ListDialog {
    data class RenameTask(val id: String, val title: String) : ListDialog
    data class DeleteTask(val id: String, val title: String) : ListDialog
    data class MoveTask(val id: String, val title: String, val listId: String) : ListDialog
    data class NewListForMove(val id: String) : ListDialog
    data class MoveCard(val id: String, val title: String) : ListDialog
    data class PlaceCard(val id: String, val title: String) : ListDialog
    data object RenameList : ListDialog
    data object DeleteList : ListDialog
    data object AddColumn : ListDialog
    data class RemoveColumn(val id: String, val title: String) : ListDialog
}

/**
 * Every task command a row offers, routed through the shared [TaskCommands]
 * (so a menu, a key and the palette do the same thing) or the screen's view
 * model where the screen owns the state (folding, the Fold celebration).
 */
@Stable
class TaskActions(
    private val vm: ListViewModel,
    private val container: AppContainer,
    private val show: (ListDialog) -> Unit,
) {
    private val commands get() = container.commands

    fun select(id: String) = vm.select(id)

    /** Tap: select; tap the selected row again: open the inspector. */
    fun tap(id: String) {
        if (vm.selectedId.value == id) container.inspector.open(id) else vm.select(id)
    }

    fun openInspector(id: String) = container.inspector.open(id)
    fun toggleComplete(id: String) = vm.toggleComplete(id)
    fun toggleInvalidate(id: String) = vm.toggleInvalidate(id)
    fun toggleFold(id: String) = vm.toggleFold(id)
    fun indent(id: String) = commands.indent(id)
    fun outdent(id: String) = commands.outdent(id)
    fun moveUp(id: String) = commands.moveUp(id)
    fun moveDown(id: String) = commands.moveDown(id)
    fun toggleList(id: String) = vm.toggleList(id)
    fun extractBranch(id: String) = commands.extractBranch(id)
    fun dueToday(id: String) = commands.dueToday(id)
    fun dueTomorrow(id: String) = commands.dueTomorrow(id)
    fun clearDue(id: String) = commands.clearDue(id)
    fun setPriority(id: String, priority: Int?) = commands.setPriority(id, priority)
    fun togglePlannedToday(id: String) = commands.togglePlannedToday(id)
    fun toggleDaily(id: String) = commands.toggleDaily(id)
    fun startFocus(id: String) = commands.startFocus(id)
    fun moveToList(id: String, listId: String) = commands.moveToList(id, listId)
    fun moveToNewList(id: String, name: String) = commands.moveToNewList(id, name)
    fun rename(id: String, title: String) = commands.rename(id, title)
    fun delete(id: String) = commands.delete(id)

    fun askRename(row: OutlineRow) = show(ListDialog.RenameTask(row.id, row.title))
    fun askDelete(row: OutlineRow) = show(ListDialog.DeleteTask(row.id, row.title))
    fun askMove(row: OutlineRow) = show(ListDialog.MoveTask(row.id, row.title, row.listId))
    fun askMoveCard(row: OutlineRow) = show(ListDialog.MoveCard(row.id, row.title))
    fun askPlace(row: OutlineRow) = show(ListDialog.PlaceCard(row.id, row.title))

    /**
     * The keys every task view shares, on the selected [row]. Returns true when
     * it handled the event. Navigation (j/k) is the view's own.
     */
    fun handleKey(event: KeyEvent, row: OutlineRow?): Boolean {
        if (event.type != KeyEventType.KeyDown || row == null) return false
        val id = row.id
        val action: (() -> Unit)? = when {
            Chord(Key.Enter).matches(event) || Chord(Key.NumPadEnter).matches(event) -> { { openInspector(id) } }
            Chord(Key.I).matches(event) -> { { openInspector(id) } }
            Chord(Key.Spacebar).matches(event) || Chord(Key.X).matches(event) -> { { toggleComplete(id) } }
            Chord(Key.Spacebar, shift = true).matches(event) -> { { toggleInvalidate(id) } }
            Chord(Key.Tab).matches(event) -> { { indent(id) } }
            Chord(Key.Tab, shift = true).matches(event) -> { { outdent(id) } }
            Chord(Key.DirectionUp, alt = true).matches(event) -> { { moveUp(id) } }
            Chord(Key.DirectionDown, alt = true).matches(event) -> { { moveDown(id) } }
            Chord(Key.Z).matches(event) -> { { toggleFold(id) } }
            Chord(Key.Delete).matches(event) || Chord(Key.Backspace).matches(event) -> { { askDelete(row) } }
            Chord(Key.F2).matches(event) -> { { askRename(row) } }
            Chord(Key.F).matches(event) -> { { startFocus(id) } }
            Chord(Key.T, alt = true).matches(event) -> { { togglePlannedToday(id) } }
            Chord(Key.T, ctrl = true).matches(event) -> { { dueToday(id) } }
            Chord(Key.T, ctrl = true, shift = true).matches(event) -> { { dueTomorrow(id) } }
            Chord(Key.D, ctrl = true, shift = true).matches(event) -> { { toggleDaily(id) } }
            Chord(Key.L, ctrl = true, shift = true).matches(event) -> { { toggleList(id) } }
            Chord(Key.M, ctrl = true, shift = true).matches(event) -> { { askMove(row) } }
            Chord(Key.Zero).matches(event) -> { { setPriority(id, null) } }
            Chord(Key.One).matches(event) -> { { setPriority(id, 1) } }
            Chord(Key.Two).matches(event) -> { { setPriority(id, 2) } }
            Chord(Key.Three).matches(event) -> { { setPriority(id, 3) } }
            Chord(Key.Four).matches(event) -> { { setPriority(id, 4) } }
            else -> null
        }
        action?.invoke()
        return action != null
    }

    /** The selected task's commands for the palette (Ctrl+K). */
    fun paletteCommands(row: OutlineRow?): List<PaletteCommand> {
        if (row == null) return emptyList()
        val id = row.id
        return listOf(
            KeyCommand.PLAN_ENTER_TASK.palette { openInspector(id) },
            KeyCommand.TASK_COMPLETE.palette { toggleComplete(id) },
            KeyCommand.TASK_INVALIDATE.palette { toggleInvalidate(id) },
            KeyCommand.TASK_INDENT.palette { indent(id) },
            KeyCommand.TASK_OUTDENT.palette { outdent(id) },
            KeyCommand.TASK_MOVE_UP.palette { moveUp(id) },
            KeyCommand.TASK_MOVE_DOWN.palette { moveDown(id) },
            KeyCommand.TASK_MOVE.palette { askMove(row) },
            KeyCommand.TASK_CONVERT_TO_LIST.palette { toggleList(id) },
            KeyCommand.TASK_EXTRACT_BRANCH.palette { extractBranch(id) },
            KeyCommand.TASK_DUE_TODAY.palette { dueToday(id) },
            KeyCommand.TASK_DUE_TOMORROW.palette { dueTomorrow(id) },
            KeyCommand.TASK_CLEAR_DUE.palette { clearDue(id) },
            KeyCommand.TASK_CLEAR_PRIORITY.palette { setPriority(id, null) },
            KeyCommand.TASK_TOGGLE_PLANNED_TODAY.palette { togglePlannedToday(id) },
            KeyCommand.TASK_TOGGLE_DAILY.palette { toggleDaily(id) },
            KeyCommand.TASK_START_FOCUS.palette { startFocus(id) },
            KeyCommand.TASK_TOGGLE_INSPECTOR.palette { openInspector(id) },
            KeyCommand.PLAN_TOGGLE_FOLD.palette { toggleFold(id) },
            KeyCommand.TASK_RENAME.palette { askRename(row) },
            KeyCommand.TASK_DELETE.palette { askDelete(row) },
        )
    }
}

/**
 * Every task command, as menu items, for a long-press menu. [structure]
 * offers indent/outdent and reorder, which only make sense where the row
 * sits in its tree.
 */
@Composable
internal fun ColumnScope.TaskMenuItems(
    row: OutlineRow,
    actions: TaskActions,
    close: () -> Unit,
    structure: Boolean = true,
) {
    fun run(block: () -> Unit): () -> Unit = {
        close()
        block()
    }
    val id = row.id
    PMenuItem("Open", Icons.Filled.Info, trailing = "Enter", onClick = run { actions.openInspector(id) })
    PMenuItem(
        if (row.status == TaskStatus.OPEN) "Complete" else "Reopen", Icons.Filled.Check, trailing = "Space",
        onClick = run { actions.toggleComplete(id) },
    )
    PMenuItem(
        if (row.status == TaskStatus.CANCELLED) "Reinstate" else "Cancel task", Icons.Filled.Close,
        onClick = run { actions.toggleInvalidate(id) },
    )
    PMenuDivider()
    if (structure) {
        PMenuItem("Indent", PIcons.Indent, trailing = "Tab", onClick = run { actions.indent(id) })
        PMenuItem("Outdent", PIcons.Outdent, trailing = "Shift+Tab", onClick = run { actions.outdent(id) })
        PMenuItem("Move up", Icons.Filled.KeyboardArrowUp, trailing = "Alt+Up", onClick = run { actions.moveUp(id) })
        PMenuItem("Move down", Icons.Filled.KeyboardArrowDown, trailing = "Alt+Down", onClick = run { actions.moveDown(id) })
    }
    PMenuItem("Move to list…", PIcons.ListIcon, onClick = run { actions.askMove(row) })
    PMenuItem(if (row.isList) "Convert to task" else "Convert to list", ListIcons.Nested, onClick = run { actions.toggleList(id) })
    PMenuItem("Extract branch as list", PIcons.Folder, onClick = run { actions.extractBranch(id) })
    PMenuDivider()
    PMenuItem("Due today", PIcons.Calendar, onClick = run { actions.dueToday(id) })
    PMenuItem("Due tomorrow", PIcons.Calendar, onClick = run { actions.dueTomorrow(id) })
    if (row.due != null) PMenuItem("Clear due date", Icons.Filled.Clear, onClick = run { actions.clearDue(id) })
    for (priority in 1..4) {
        PMenuItem("Priority $priority", PIcons.Flag, trailing = if (row.priority == priority) "Set" else null, onClick = run { actions.setPriority(id, priority) })
    }
    if (row.priority != null) PMenuItem("No priority", PIcons.Flag, onClick = run { actions.setPriority(id, null) })
    PMenuDivider()
    PMenuItem(if (row.isPlanned) "Take off today" else "Plan for today", PIcons.Today, onClick = run { actions.togglePlannedToday(id) })
    PMenuItem(if (row.isDaily) "Stop daily" else "Make daily", PIcons.Repeat, onClick = run { actions.toggleDaily(id) })
    PMenuItem("Start focus", Icons.Filled.PlayArrow, trailing = "F", onClick = run { actions.startFocus(id) })
    PMenuDivider()
    PMenuItem("Rename…", Icons.Filled.Edit, trailing = "F2", onClick = run { actions.askRename(row) })
    PMenuItem("Delete…", Icons.Filled.Delete, destructive = true, onClick = run { actions.askDelete(row) })
}
