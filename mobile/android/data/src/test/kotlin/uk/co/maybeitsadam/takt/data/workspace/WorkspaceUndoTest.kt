package uk.co.maybeitsadam.takt.data.workspace

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.core.TaskStatus
import uk.co.maybeitsadam.takt.core.WorkspaceKanbanColumn
import uk.co.maybeitsadam.takt.data.TestWorkspace

/**
 * Port of workspace-tests/WorkspaceUndoTests.swift.
 * `testImportingIsNotRecordedAsThousandsOfSteps` is not ported (import).
 */
class WorkspaceUndoTest {
    private class Fixture(val w: TestWorkspace, val workspaceId: String, val listId: String) {
        val store get() = w.repository
    }

    private fun fixture(test: suspend Fixture.() -> Unit): Unit = runBlocking {
        workspace().use { w ->
            val workspaceId = w.repository.bootstrapIfNeeded().id
            Fixture(w, workspaceId, w.repository.inbox(workspaceId)!!.id).test()
        }
    }

    @Test
    fun nothingToUndoOnAFreshWorkspace() = fixture {
        assertNull(store.undoableLabel())
        assertNull(store.redoableLabel())
        assertNull(store.undo())
    }

    @Test
    fun undoTakesBackACreationAndRedoPutsItBack() = fixture {
        val task = store.createTask(listId = listId, title = "Write the report")
        assertEquals("New Task", store.undoableLabel())
        assertEquals("New Task", store.undo())
        assertNull(store.task(task.id))
        assertEquals("New Task", store.redoableLabel())
        assertEquals("New Task", store.redo())
        assertEquals("Write the report", store.task(task.id)?.title)
    }

    @Test
    fun boardCreationAtTopIsOneCompleteUndoStep() = fixture {
        val existing = store.createTask(listId = listId, title = "Existing")
        val added = store.createTask(listId = listId, title = "New card", kanbanColumn = "today", atTop = true)
        assertEquals(listOf(added.id, existing.id), store.tasks(listId).map { it.id })
        assertEquals("New Task", store.undo())
        assertNull(store.task(added.id))
        assertEquals(listOf(existing.id), store.tasks(listId).map { it.id })
        store.redo()
        assertEquals(listOf(added.id, existing.id), store.tasks(listId).map { it.id })
        assertEquals("today", store.kanbanColumn(added.id))
    }

    @Test
    fun columnPlacementAndReorderingUndoTogether() = fixture {
        val first = store.createTask(listId = listId, title = "First", kanbanColumn = "backlog")
        val second = store.createTask(listId = listId, title = "Second", kanbanColumn = "today")
        store.moveTaskBefore(second.id, first.id, kanbanColumn = "backlog")
        assertEquals("Reorder Task", store.undo())
        assertEquals(listOf(first.id, second.id), store.tasks(listId).map { it.id })
        assertEquals("today", store.kanbanColumn(second.id))
        store.redo()
        assertEquals(listOf(second.id, first.id), store.tasks(listId).map { it.id })
        assertEquals("backlog", store.kanbanColumn(second.id))
    }

    @Test
    fun boardHistoryPersistsAndLegacyPreferencesDoNotOverwriteIt() = fixture {
        val key = "$listId/root"
        val baseline = WorkspaceKanbanColumn.blitzitDefaults
        val legacy = mapOf(key to KanbanColumnsCodec.encode(baseline))
        store.kanbanBoardConfigurations(legacy, key)
        val custom = baseline + WorkspaceKanbanColumn("custom", "Custom")
        store.setKanbanBoardColumns(custom, key, label = "Add Board Column")
        w.reopened { reopened ->
            assertEquals("Add Board Column", reopened.undo())
            assertEquals(baseline, reopened.kanbanBoardConfigurations(legacy, key)[key])
            assertEquals("Add Board Column", reopened.redo())
            assertEquals(custom, reopened.kanbanBoardConfigurations(legacy, key)[key])
        }
    }

    @Test
    fun columnRemovalAndItsCardsUndoTogether() = fixture {
        val key = "$listId/root"
        val defaults = WorkspaceKanbanColumn.blitzitDefaults
        store.kanbanBoardConfigurations(emptyMap(), key)
        val card = store.createTask(listId = listId, title = "Today", kanbanColumn = "today")
        val remaining = defaults.filter { it.id != "today" }
        store.setKanbanBoardColumns(
            remaining, key, movingTaskIds = listOf(card.id), toColumn = "backlog", label = "Remove Board Column",
        )
        assertEquals("Remove Board Column", store.undo())
        assertEquals(defaults, store.kanbanBoardConfigurations(emptyMap(), key)[key])
        assertEquals("today", store.kanbanColumn(card.id))
        store.redo()
        assertEquals(remaining, store.kanbanBoardConfigurations(emptyMap(), key)[key])
        assertEquals("backlog", store.kanbanColumn(card.id))
    }

    @Test
    fun relativeCreationPreservesSiblingOrderAndUndoesInOneStep() = fixture {
        val first = store.createTask(listId = listId, title = "First")
        val last = store.createTask(listId = listId, title = "Last")
        val middle = store.createTask(listId = listId, title = "Middle", adjacentTaskId = last.id, above = true)
        assertEquals(listOf(first.id, middle.id, last.id), store.tasks(listId).map { it.id })
        store.undo()
        assertEquals(listOf(first.id, last.id), store.tasks(listId).map { it.id })
        store.redo()
        assertEquals(listOf(first.id, middle.id, last.id), store.tasks(listId).map { it.id })
    }

    @Test
    fun failedCreationDoesNotLeaveAPartialTaskOrDestroyRedo() = fixture {
        val first = store.createTask(listId = listId, title = "First")
        store.updateTask(first.id, "Changed", "", null, null)
        store.undo()
        thrown { store.createTask(listId = listId, title = "Bad", kanbanColumn = "today", adjacentTaskId = "missing") }
        assertEquals(listOf(first.id), store.tasks(listId).map { it.id })
        assertEquals("Edit Task", store.redoableLabel())
    }

    @Test
    fun undoFocusCompletionReopensWorkWithoutErasingElapsedTime() = fixture {
        val task = store.createTask(listId = listId, title = "Focus task")
        val session = store.startFocusSession(taskId = task.id)
        store.completeActiveFocusTask(sessionId = session.id, elapsedSeconds = 600)
        assertEquals("Complete Task", store.undo())
        assertEquals(TaskStatus.OPEN, store.task(task.id)?.status)
        assertEquals(listOf(600), store.workBlocks(task.id).map { it.seconds })
        store.redo()
        assertEquals(TaskStatus.COMPLETED, store.task(task.id)?.status)
        assertEquals(listOf(600), store.workBlocks(task.id).map { it.seconds })
    }

    @Test
    fun undoRestoresAnEditedTitleWithoutTouchingItsSubtree() = fixture {
        val parent = store.createTask(listId = listId, title = "Original")
        val child = store.createTask(listId = listId, title = "Child", parentTaskId = parent.id)
        store.updateTask(parent.id, "Renamed", "note", null, null)
        assertEquals("Edit Task", store.undo())
        assertEquals("Original", store.task(parent.id)?.title)
        assertEquals(parent.id, store.task(child.id)?.parentTaskId)
    }

    @Test
    fun undoRestoresADeletedSubtreeWhole() = fixture {
        val parent = store.createTask(listId = listId, title = "Parent")
        val child = store.createTask(listId = listId, title = "Child", parentTaskId = parent.id)
        val grandchild = store.createTask(listId = listId, title = "Grandchild", parentTaskId = child.id)
        store.setKanbanColumn("today", grandchild.id)
        store.deleteTask(parent.id)
        assertTrue(store.outline(listId).isEmpty())
        assertEquals("Delete Task", store.undo())
        assertEquals(listOf("Parent", "Child", "Grandchild"), store.outline(listId).map { it.task.title })
        assertEquals(listOf(0, 1, 2), store.outline(listId).map { it.depth })
        assertEquals("today", store.kanbanColumn(grandchild.id))
    }

    @Test
    fun undoRestoresADeletedListAndEverythingInIt() = fixture {
        val list = store.createList(workspaceId = workspaceId, name = "Project")
        val task = store.createTask(listId = list.id, title = "Ship it")
        store.deleteList(list.id)
        assertEquals("Delete List", store.undo())
        assertTrue(store.lists(workspaceId).any { it.id == list.id })
        assertEquals("Ship it", store.task(task.id)?.title)
    }

    @Test
    fun oneOperationIsOneUndoStepHoweverManyRowsItTouched() = fixture {
        store.createTask(listId = listId, title = "First")
        store.createTask(listId = listId, title = "Second")
        val third = store.createTask(listId = listId, title = "Third")
        store.moveTaskWithinSiblings(third.id, -2)
        assertEquals(listOf("Third", "First", "Second"), store.outline(listId).map { it.task.title })
        assertEquals("Reorder Task", store.undo())
        assertEquals(listOf("First", "Second", "Third"), store.outline(listId).map { it.task.title })
        assertEquals("New Task", store.undoableLabel())
    }

    @Test
    fun undoingSeveralStepsWalksBackInOrder() = fixture {
        val task = store.createTask(listId = listId, title = "One")
        store.updateTask(task.id, "Two", "", null, null)
        store.updateTask(task.id, "Three", "", null, null)
        store.undo()
        assertEquals("Two", store.task(task.id)?.title)
        store.undo()
        assertEquals("One", store.task(task.id)?.title)
        store.undo()
        assertNull(store.task(task.id))
        assertNull(store.undo())
        store.redo()
        assertEquals("One", store.task(task.id)?.title)
        store.redo()
        store.redo()
        assertEquals("Three", store.task(task.id)?.title)
        assertNull(store.redo())
    }

    @Test
    fun aNewEditAfterAnUndoClearsTheRedoStack() = fixture {
        val task = store.createTask(listId = listId, title = "One")
        store.updateTask(task.id, "Two", "", null, null)
        store.undo()
        assertNotNull(store.redoableLabel())
        store.updateTask(task.id, "Different", "", null, null)
        assertNull(store.redoableLabel())
        assertNull(store.redo())
        assertEquals("Different", store.task(task.id)?.title)
    }

    @Test
    fun undoingIsNotItselfAnUndoStep() = fixture {
        val task = store.createTask(listId = listId, title = "One")
        store.updateTask(task.id, "Two", "", null, null)
        store.undo()
        assertEquals("New Task", store.undoableLabel())
    }

    @Test
    fun theSearchIndexFollowsAnUndo() = fixture {
        val task = store.createTask(listId = listId, title = "Findable widget")
        assertEquals(1, store.searchTasks(workspaceId, "widget").size)
        store.undo()
        assertTrue(store.searchTasks(workspaceId, "widget").isEmpty())
        store.redo()
        assertEquals(listOf(task.id), store.searchTasks(workspaceId, "widget").map { it.task.id })
    }

    @Test
    fun theJournalDoesNotGrowWithoutBound() = fixture {
        for (index in 0 until 140) store.createTask(listId = listId, title = "Task $index")
        val groups = w.otherConnection { it.long("SELECT COUNT(DISTINCT groupId) FROM change_log") ?: 0L }
        assertTrue(groups in 1..100)
        assertEquals("New Task", store.undo())
    }
}
