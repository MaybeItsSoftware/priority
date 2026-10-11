package uk.co.maybeitsadam.takt.data.workspace

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.core.TaskList
import uk.co.maybeitsadam.takt.core.TaskStatus
import uk.co.maybeitsadam.takt.core.Workspace
import uk.co.maybeitsadam.takt.data.TestWorkspace

/** Task dependencies through the repository: the Rust core's `dependencies`, as the phone reaches it. */
class WorkspaceDependenciesTest {
    private class Fixture(val w: TestWorkspace, val workspace: Workspace, val list: TaskList) {
        val store get() = w.repository

        suspend fun titles(): List<String> = store.outline(list.id).map { it.task.title }
    }

    private fun fixture(test: suspend Fixture.() -> Unit): Unit = runBlocking {
        workspace().use { w ->
            val ws = w.repository.bootstrapIfNeeded()
            Fixture(w, ws, w.repository.createList(ws.id, "Work")).test()
        }
    }

    @Test
    fun aBlockerIsAddedListedAndRemovedAsUndoableSteps() = fixture {
        val ship = store.createTask(listId = list.id, title = "Ship")
        val review = store.createTask(listId = list.id, title = "Review")

        assertTrue(store.addBlocker(ship.id, review.id))
        assertEquals("Add Blocker", store.undoableLabel())
        assertFalse("adding it again changes nothing", store.addBlocker(ship.id, review.id))
        assertEquals(listOf(review.id), store.blockers(ship.id).map { it.id })
        assertEquals(listOf(ship.id), store.blocking(review.id).map { it.id })
        assertTrue(store.isBlocked(ship.id))
        assertFalse(store.isBlocked(review.id))
        assertEquals(setOf(ship.id), store.blockedTaskIds())
        assertEquals(TaskDependencies(listOf(review), emptyList(), isBlocked = true), store.taskDependencies(ship.id))

        assertTrue(store.removeBlocker(ship.id, review.id))
        assertEquals("Remove Blocker", store.undoableLabel())
        assertFalse(store.removeBlocker(ship.id, review.id))
        assertTrue(store.blockers(ship.id).isEmpty())
        assertTrue(store.blockedTaskIds().isEmpty())

        store.undo()
        assertEquals(setOf(ship.id), store.blockedTaskIds())
    }

    @Test
    fun aCycleOrATaskWaitingOnItselfIsRefused() = fixture {
        val a = store.createTask(listId = list.id, title = "A")
        val b = store.createTask(listId = list.id, title = "B")
        val c = store.createTask(listId = list.id, title = "C")
        store.addBlocker(a.id, b.id)
        store.addBlocker(b.id, c.id)

        assertStoreError(WorkspaceStoreError.DEPENDENCY_CYCLE) { store.addBlocker(a.id, a.id) }
        assertStoreError(WorkspaceStoreError.DEPENDENCY_CYCLE) { store.addBlocker(c.id, a.id) }
        assertStoreError(WorkspaceStoreError.MISSING_TASK) { store.addBlocker(a.id, "no-such-task") }
        assertEquals(setOf(a.id, b.id), store.blockedTaskIds())
    }

    @Test
    fun aBlockedTaskSinksBelowItsSiblingsUntilItsBlockerIsDone() = fixture {
        val first = store.createTask(listId = list.id, title = "First")
        store.createTask(listId = list.id, title = "Second")
        val third = store.createTask(listId = list.id, title = "Third")
        store.addBlocker(first.id, third.id)

        assertEquals(listOf("Second", "Third", "First"), titles())
        assertEquals(listOf("Second", "Third", "First"), store.listScope(workspace.id, list.id).trees.getValue(list.id).children(null).map { it.title })

        store.setStatus(TaskStatus.COMPLETED, third.id)
        assertEquals("a done blocker holds nothing back", listOf("First", "Second", "Third"), titles())
        assertTrue(store.blockedTaskIds().isEmpty())
    }

    @Test
    fun aBlockedTaskIsNotANextUpCandidate() = fixture {
        val ship = store.createTask(listId = list.id, title = "Ship")
        val review = store.createTask(listId = list.id, title = "Review")
        store.addBlocker(ship.id, review.id)

        val candidates = store.nextUpCandidates().map { it.id }
        assertTrue(review.id in candidates)
        assertFalse(ship.id in candidates)
    }

    @Test
    fun theListScopeCarriesTheBlockedIdsAndRereadsWhenOnlyAnEdgeArrives() = fixture {
        val ship = store.createTask(listId = list.id, title = "Ship")
        val review = store.createTask(listId = list.id, title = "Review")
        assertTrue(store.observeListScope(workspace.id, list.id).first().blockedTaskIds.isEmpty())

        // A sync pull writes the row through the database's own writer, which
        // reports `task_dependencies` alone; the scope must still re-read.
        val emissions = store.observeListScope(workspace.id, list.id)
        withTimeout(5_000) {
            var wrote = false
            emissions.first { scope ->
                if (!wrote) {
                    wrote = true
                    store.database.write {
                        it.execute(
                            "INSERT INTO task_dependencies (id, taskId, blockedByTaskId, createdAt) VALUES (?, ?, ?, ?)",
                            "edge", ship.id, review.id, "2026-10-11 10:00:00.000",
                        )
                    }
                }
                ship.id in scope.blockedTaskIds
            }
        }
        assertEquals(setOf(ship.id), store.observeBlockedTaskIds().first())
        assertEquals(listOf(review.id), store.observeTaskDependencies(ship.id).first().blockers.map { it.id })
    }

    @Test
    fun deletingABlockerDropsTheEdge() = fixture {
        val ship = store.createTask(listId = list.id, title = "Ship")
        val review = store.createTask(listId = list.id, title = "Review")
        store.addBlocker(ship.id, review.id)
        store.deleteTask(review.id)

        assertTrue(store.blockers(ship.id).isEmpty())
        assertFalse(store.isBlocked(ship.id))
    }
}
