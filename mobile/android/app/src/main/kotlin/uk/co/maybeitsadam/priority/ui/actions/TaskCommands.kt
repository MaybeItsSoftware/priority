package uk.co.maybeitsadam.priority.ui.actions

import java.time.Instant
import java.time.ZoneId
import uk.co.maybeitsadam.priority.app.AppContainer
import uk.co.maybeitsadam.priority.core.NextUpSelector
import uk.co.maybeitsadam.priority.core.TaskStatus
import uk.co.maybeitsadam.priority.core.WorkspaceItemKind
import uk.co.maybeitsadam.priority.core.WorkspaceTask

/**
 * Every Task-group command from the desktop catalogue
 * (`WorkspaceCommandCatalog+Entries.swift`), as one call each. Long-press
 * menus, swipes, keyboard shortcuts and the command palette all land here, so
 * a command behaves the same from every surface. Each is one undo step.
 */
class TaskCommands(private val container: AppContainer) {
    private val undo get() = container.undo

    private fun startOfDay(offsetDays: Long): Instant {
        val zone = ZoneId.systemDefault()
        return java.time.LocalDate.now(zone).plusDays(offsetDays).atStartOfDay(zone).toInstant()
    }

    /** Space / x: complete an open task, reopen a closed one. */
    fun toggleComplete(task: WorkspaceTask) = undo.perform { repo ->
        repo.setStatus(if (task.status == TaskStatus.OPEN) TaskStatus.COMPLETED else TaskStatus.OPEN, task.id)
    }

    fun complete(taskId: String) = undo.perform { it.setStatus(TaskStatus.COMPLETED, taskId) }

    fun reopen(taskId: String) = undo.perform { it.setStatus(TaskStatus.OPEN, taskId) }

    /** Shift+Space: cancel (it stopped mattering), or reinstate. */
    fun toggleInvalidate(task: WorkspaceTask) = undo.perform { repo ->
        repo.setStatus(if (task.status == TaskStatus.CANCELLED) TaskStatus.OPEN else TaskStatus.CANCELLED, task.id)
    }

    fun indent(taskId: String) = undo.perform { it.indentTask(taskId) }

    fun outdent(taskId: String) = undo.perform { it.outdentTask(taskId) }

    fun moveUp(taskId: String) = undo.perform { it.moveTaskWithinSiblings(taskId, -1) }

    fun moveDown(taskId: String) = undo.perform { it.moveTaskWithinSiblings(taskId, 1) }

    /** Files the task (and its subtree) at the top level of another list. */
    fun moveToList(taskId: String, listId: String) =
        undo.perform { it.moveTask(taskId, listId, toVisibleRoot = true) }

    /** "New list …" in the move picker: creates the list, then moves the task into it, as two steps. */
    fun moveToNewList(taskId: String, name: String, folderId: String? = null) = undo.perform { repo ->
        val session = container.awaitSession()
        val list = repo.createList(session.workspace.id, name, folderId)
        repo.moveTask(taskId, list.id, toVisibleRoot = true)
    }

    /** Cmd+Shift+L: a task becomes a nested list, or a nested list goes back to a task. */
    fun toggleList(task: WorkspaceTask) = undo.perform { repo ->
        repo.setItemKind(if (task.isList) WorkspaceItemKind.TASK else WorkspaceItemKind.LIST, task.id)
    }

    /** xx: the branch becomes a standalone list in [folderId]. */
    fun extractBranch(taskId: String, folderId: String? = null) = undo.perform { it.moveTaskToFolder(taskId, folderId) }

    fun dueToday(taskId: String) = setDue(taskId, startOfDay(0))

    fun dueTomorrow(taskId: String) = setDue(taskId, startOfDay(1))

    fun clearDue(taskId: String) = setDue(taskId, null)

    fun setDue(taskId: String, dueAt: Instant?) = undo.perform { repo ->
        val task = repo.task(taskId) ?: return@perform
        repo.updateTask(task.id, task.title, task.notes, dueAt, task.estimateSeconds)
    }

    fun rename(taskId: String, title: String) = undo.perform { repo ->
        val task = repo.task(taskId) ?: return@perform
        if (task.title == title.trim()) return@perform
        repo.updateTask(task.id, title, task.notes, task.dueAt, task.estimateSeconds)
    }

    /** 1 (urgent) to 4; 0 or null clears it. */
    fun setPriority(taskId: String, priority: Int?) = undo.perform { repo ->
        val metadata = repo.taskEditorMetadata(taskId)
        repo.updateTaskEditorMetadata(taskId, metadata.copy(priority = priority?.takeIf { it in 1..4 }))
    }

    /** Ctrl+T: put it in Today, or take it off. */
    fun togglePlannedToday(taskId: String) = undo.perform { repo ->
        val planned = repo.kanbanColumn(taskId) == NextUpSelector.todayColumnID
        repo.setPlannedForToday(!planned, listOf(taskId))
    }

    /** Cmd+Shift+D: commit to it every day, or stop. */
    fun toggleDaily(taskId: String) = undo.perform { repo ->
        if (repo.daily(taskId) != null) repo.archiveDaily(taskId) else repo.makeDaily(taskId)
    }

    /** f: start a focus block on the task. Not an undo step; the focus service picks it up. */
    fun startFocus(taskId: String, plannedSeconds: Int? = null) = undo.perform(announce = false) { repo ->
        repo.startFocusSession(taskId, plannedSeconds = plannedSeconds)
        undo.say("Focus started")
    }

    fun delete(taskId: String) = undo.perform { it.deleteTask(taskId) }
}
