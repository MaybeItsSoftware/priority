package uk.co.maybeitsadam.priority.data.workspace

import java.time.Instant
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.priority.core.TaskList
import uk.co.maybeitsadam.priority.core.TaskStatus
import uk.co.maybeitsadam.priority.data.TestWorkspace

class WorkspaceReviewReadsTest {
    private fun fixture(test: suspend (TestWorkspace, TaskList) -> Unit): Unit = runBlocking {
        workspace().use { w ->
            val workspace = w.repository.bootstrapIfNeeded()
            test(w, w.repository.inbox(workspace.id)!!)
        }
    }

    private val wide = Instant.EPOCH to Instant.parse("2100-01-01T00:00:00Z")

    @Test
    fun completedTasksAreNewestFirstAndKeepCancellations() = fixture { w, list ->
        val store = w.repository
        val first = store.createTask(listId = list.id, title = "First")
        val second = store.createTask(listId = list.id, title = "Second")
        store.createTask(listId = list.id, title = "Still open")
        store.setStatus(TaskStatus.COMPLETED, first.id)
        store.setStatus(TaskStatus.CANCELLED, second.id)

        val done = store.observeCompletedTasks(Instant.EPOCH).first()
        assertEquals(listOf("Second", "First"), done.map { it.title })
        assertEquals(TaskStatus.CANCELLED, done.first().status)
    }

    @Test
    fun progressReadsCompletionsCreationsAndBlocks() = fixture { w, list ->
        val store = w.repository
        val task = store.createTask(listId = list.id, title = "Draft")
        store.createTask(listId = list.id, title = "Other")
        val session = store.startFocusSession(taskId = task.id)
        store.completeActiveFocusTask(sessionId = session.id, elapsedSeconds = 600)

        val records = store.observeReviewProgress(wide.first, wide.second).first()
        assertEquals(2, records.creations.size)
        assertEquals(1, records.completions.size)
        assertEquals(600, records.blocks.sumOf { it.seconds })
    }

    @Test
    fun theDayReadCarriesBlocksAndNoSessionOnceFinished() = fixture { w, list ->
        val store = w.repository
        val task = store.createTask(listId = list.id, title = "Draft")
        val session = store.startFocusSession(taskId = task.id)
        store.completeActiveFocusTask(sessionId = session.id, elapsedSeconds = 900, completeTask = false)
        store.finishFocusSession(session.id)

        val day = store.observeReviewDay(wide.first, wide.second).first()
        assertEquals(listOf("Draft"), day.blocks.map { it.taskTitle })
        assertNull(day.activeSession)
        assertNull(day.activeTaskTitle)
        assertTrue(day.closedTasks.isEmpty())
    }

    @Test
    fun historyIsLiveAndMarksUndoneSteps() = fixture { w, list ->
        val store = w.repository
        store.createTask(listId = list.id, title = "One")
        store.createTask(listId = list.id, title = "Two")
        val before = store.observeHistory().first()
        assertTrue(before.size >= 2)
        assertFalse(before.first().isUndone)

        store.undo()
        val after = store.observeHistory().first()
        assertTrue(after.first().isUndone)
        assertFalse(after[1].isUndone)
        assertEquals(store.history(), after)
    }
}
