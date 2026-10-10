package uk.co.maybeitsadam.takt.data.workspace

import java.time.Instant
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.core.TaskList
import uk.co.maybeitsadam.takt.core.TaskProgressPeriod
import uk.co.maybeitsadam.takt.core.TaskStatus
import uk.co.maybeitsadam.takt.data.TestWorkspace

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

        val progress = store.observeReviewProgress(TaskProgressPeriod.WEEK).first()
        assertEquals(7, progress.days.size)
        assertEquals(2, progress.totalAdded)
        assertEquals(1, progress.totalCompleted)
        assertEquals(10, progress.focusMinutes)
        assertEquals(6, progress.bestDay)
        assertEquals(10, progress.days.last().focusMinutes)
        assertEquals(2, progress.days.last().cumulativeAdded)
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
