package uk.co.maybeitsadam.priority.data.workspace

import java.time.Instant
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.priority.core.TaskMatrixPosition

class WorkspaceInspectorFactsTest {
    private val now: Instant = epoch(1_789_560_000)

    @Test
    fun aFreshTaskHasNoPlacementDailyOrLoggedWork() = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded()
            val inbox = store.inbox(workspace.id)!!
            val task = store.createTask(listId = inbox.id, title = "Write report")
            val facts = store.taskInspectorFacts(task.id)
            assertNull(facts.kanbanColumn)
            assertEquals(TaskMatrixPosition(null, null), facts.matrix)
            assertNull(facts.daily)
            assertEquals(0, facts.loggedSeconds)
            assertFalse(facts.isPlannedToday)
        }
    }

    @Test
    fun factsFollowTodayMatrixDailyAndFocusWork() = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded()
            val inbox = store.inbox(workspace.id)!!
            val task = store.createTask(listId = inbox.id, title = "Write report", now = now)
            store.updateTask(task.id, "Write report", "", null, 3600, now = now)

            store.setPlannedForToday(true, listOf(task.id))
            store.setMatrixPosition(TaskMatrixPosition(5, -5), task.id)
            store.makeDaily(task.id, weekdays = setOf(2, 4))
            val session = store.startFocusSession(taskId = task.id, now = now)
            store.completeActiveFocusTask(
                sessionId = session.id, elapsedSeconds = 900, completeTask = false,
                expectedBlockId = session.activeBlockId, now = now.plusSeconds(900),
            )

            val facts = store.observeTaskInspectorFacts(task.id).first()
            assertTrue(facts.isPlannedToday)
            assertEquals(TaskMatrixPosition(5, -5), facts.matrix)
            assertNotNull(facts.daily)
            assertEquals(setOf(2, 4), facts.daily?.activeWeekdays)
            assertEquals(900, facts.loggedSeconds)
            assertEquals(1, facts.workBlockCount)

            store.archiveDaily(task.id)
            assertNull(store.taskInspectorFacts(task.id).daily)
        }
    }
}
