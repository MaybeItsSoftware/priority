package uk.co.maybeitsadam.takt.data.workspace

import java.time.Instant
import java.time.LocalDateTime
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.core.TaskList
import uk.co.maybeitsadam.takt.core.TaskStatus
import uk.co.maybeitsadam.takt.core.WaitingFollowUp
import uk.co.maybeitsadam.takt.data.TestWorkspace

/** Port of workspace-tests/WorkspaceWaitingTests.swift, plus the cross-device id and a follow-up arriving by sync. */
class WorkspaceWaitingTest {
    private class Fixture(val w: TestWorkspace, val list: TaskList) {
        val store get() = w.repository

        suspend fun followUps(of: String): List<String> =
            store.waitingDetails().filterValues { it.followUpOfTaskId == of }.keys.toList()
    }

    private fun fixture(test: suspend Fixture.() -> Unit): Unit = runBlocking {
        workspace().use { w ->
            val workspaceId = w.repository.bootstrapIfNeeded().id
            Fixture(w, w.repository.lists(workspaceId).first()).test()
        }
    }

    /** 6 October 2026, at [hour] UTC. */
    private fun at(hour: Int, minute: Int = 0): Instant = LocalDateTime.of(2026, 10, 6, hour, minute).toInstant(UTC)

    @Test
    fun settingWaitingFilesTheTaskInWaitingOnWithItsTagAndTime() = fixture {
        val task = store.createTask(listId = list.id, title = "Contract signed", kanbanColumn = "today")
        store.setWaiting(task.id, "  Sam ", at(14).plusSeconds(42), now = at(10))

        assertEquals("waiting-on", store.kanbanColumn(task.id))
        val details = store.waitingDetails()[task.id]
        assertEquals("Sam", details?.waitingOn)
        // Truncated to the whole minute, the instant the follow-up's id is made from.
        assertEquals(at(14), details?.followUpAt)
        assertTrue("not due yet", followUps(task.id).isEmpty())

        store.undo()
        assertEquals("today", store.kanbanColumn(task.id))
        assertNull(store.waitingDetails()[task.id])
    }

    @Test
    fun atItsTimeAStillWaitingTaskGetsOneFollowUpInToday() = fixture {
        val task = store.createTask(listId = list.id, title = "Contract signed")
        store.setWaiting(task.id, "Sam", at(14), now = at(10))

        assertFalse(store.reconcileWaitingFollowUps(now = at(13, 59)))
        assertTrue(store.reconcileWaitingFollowUps(now = at(14)))
        assertFalse("made once, not on every poll", store.reconcileWaitingFollowUps(now = at(14, 1)))

        val ids = followUps(task.id)
        assertEquals(listOf(WaitingFollowUp.followUpTaskId(task.id, at(14))), ids)
        val followUp = store.task(ids[0])!!
        assertEquals("Follow up with Sam: Contract signed", followUp.title)
        assertEquals(at(14), followUp.dueAt)
        assertEquals(task.listId, followUp.listId)
        assertEquals(task.parentTaskId, followUp.parentTaskId)
        assertEquals(task.sortOrder + 1, followUp.sortOrder)
        assertEquals("today", store.kanbanColumn(followUp.id))

        // Deleting the follow-up does not bring it back: the source records it.
        store.deleteTask(followUp.id)
        assertFalse(store.reconcileWaitingFollowUps(now = at(15)))

        // A new time is a new follow-up.
        store.setWaiting(task.id, "Sam", at(16), now = at(15))
        assertTrue(store.reconcileWaitingFollowUps(now = at(16)))
        assertEquals(1, followUps(task.id).size)
    }

    @Test
    fun aTaskThatLeftWaitingBeforeItsTimeGetsNone() = fixture {
        val task = store.createTask(listId = list.id, title = "Invoice paid")
        store.setWaiting(task.id, null, at(14), now = at(10))
        store.setKanbanColumn("in-progress", task.id)
        assertFalse(store.reconcileWaitingFollowUps(now = at(15)))

        val closed = store.createTask(listId = list.id, title = "Parcel arrived")
        store.setWaiting(closed.id, null, at(14), now = at(10))
        store.setStatus(TaskStatus.COMPLETED, closed.id)
        assertFalse(store.reconcileWaitingFollowUps(now = at(15)))
    }

    @Test
    fun aFollowUpOutlivesItsSourceLeavingWaiting() = fixture {
        val task = store.createTask(listId = list.id, title = "Invoice paid")
        store.setWaiting(task.id, null, at(14), now = at(10))
        assertTrue(store.reconcileWaitingFollowUps(now = at(14)))
        val id = followUps(task.id).first()
        assertEquals("Follow up: Invoice paid", store.task(id)?.title)

        store.setStatus(TaskStatus.COMPLETED, task.id)
        assertEquals(TaskStatus.OPEN, store.task(id)?.status)
        assertEquals("today", store.kanbanColumn(id))
    }

    /** Set after the time has passed, the follow-up is made straight away, in the same undo step. */
    @Test
    fun aTimeAlreadyPastMakesTheFollowUpAtOnce() = fixture {
        val task = store.createTask(listId = list.id, title = "Quote back")
        store.setWaiting(task.id, "Legal", at(9), now = at(10))
        assertEquals(1, followUps(task.id).size)
        store.undo()
        assertTrue(followUps(task.id).isEmpty())
    }

    /** The reconcile pass is not an undo step: undo takes back the user's last edit, not the follow-up. */
    @Test
    fun theReconcilePassIsNotAnUndoStep() = fixture {
        val task = store.createTask(listId = list.id, title = "Quote back")
        store.setWaiting(task.id, "Legal", at(14), now = at(10))
        assertTrue(store.reconcileWaitingFollowUps(now = at(14)))
        assertEquals("Waiting On", store.undoableLabel())
    }

    /** The id the Mac makes for the same source and time, so the two rows merge. */
    @Test
    fun theFollowUpHasTheIdTheMacGivesIt() = fixture {
        val source = "6F1C2A9E-0000-4000-8000-000000000001"
        w.database.write { db ->
            db.execute(
                "INSERT INTO tasks (id, listId, title, notes, status, sortOrder, createdAt, updatedAt) " +
                    "VALUES (?, ?, 'Contract signed', '', 'open', 0, ?, ?)",
                source, list.id, at(9), at(9),
            )
        }
        store.setWaiting(source, "Sam", epoch(1_791_291_600), now = at(10))
        assertTrue(store.reconcileWaitingFollowUps(now = at(13)))
        assertEquals(listOf("D2D0E044-BDD3-5ED3-95C6-C687611541D1"), followUps(source))
    }

    /** Another device made the follow-up first and sync brought it: it is kept and recorded, not duplicated. */
    @Test
    fun aFollowUpThatArrivedBySyncIsRecordedNotDuplicated() = fixture {
        val task = store.createTask(listId = list.id, title = "Contract signed")
        store.setWaiting(task.id, "Sam", at(14), now = at(10))
        val id = WaitingFollowUp.followUpTaskId(task.id, at(14))
        w.database.write { db ->
            db.execute(
                "INSERT INTO tasks (id, listId, title, notes, status, sortOrder, createdAt, updatedAt) " +
                    "VALUES (?, ?, 'Follow up with Sam: Contract signed', '', 'open', 7, ?, ?)",
                id, list.id, at(14), at(14),
            )
        }
        val before = store.tasks(list.id).size
        assertTrue(store.reconcileWaitingFollowUps(now = at(14, 1)))
        assertEquals(before, store.tasks(list.id).size)
        assertEquals(7, store.task(id)?.sortOrder)
        assertFalse(store.reconcileWaitingFollowUps(now = at(14, 2)))
        assertNotNull(store.task(id))
    }
}
