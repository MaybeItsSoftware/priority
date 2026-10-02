package uk.co.maybeitsadam.priority.data.workspace

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test
import uk.co.maybeitsadam.priority.core.DayPlanReason
import uk.co.maybeitsadam.priority.core.FocusContext
import uk.co.maybeitsadam.priority.core.NextUpSelector
import uk.co.maybeitsadam.priority.core.TaskList
import uk.co.maybeitsadam.priority.data.TestWorkspace

/** Port of workspace-tests/WorkspaceTodayTests.swift. */
class WorkspaceTodayTest {
    private class Fixture(val w: TestWorkspace, val workspaceId: String, val work: TaskList, val home: TaskList) {
        val store get() = w.repository

        suspend fun plannedOrder(): List<String> =
            store.nextUpSnapshot(workspaceId, FocusContext(), null).todayPlan
                .filter { it.reason == DayPlanReason.PLANNED }.map { it.id }
    }

    private fun fixture(test: suspend Fixture.() -> Unit): Unit = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val workspaceId = store.bootstrapIfNeeded().id
            Fixture(
                w, workspaceId,
                store.createList(workspaceId = workspaceId, name = "Work"),
                store.createList(workspaceId = workspaceId, name = "Home"),
            ).test()
        }
    }

    @Test
    fun aTypedTaskCarriesItsDetails() = fixture {
        val due = w.clock.instant.atZone(UTC).toLocalDate().atStartOfDay(UTC).toInstant()
        val task = store.createTask(
            listId = work.id, title = "Write notes", dueAt = due, estimateSeconds = 45 * 60,
            tags = listOf("work", " Work ", "q4"), priority = 2,
        )
        assertEquals(due, task.dueAt)
        assertEquals(45 * 60, task.estimateSeconds)
        val metadata = store.taskEditorMetadata(task.id)
        assertEquals(listOf("work", "q4"), metadata.tags)
        assertEquals(2, metadata.priority)
    }

    @Test
    fun detailsOutOfRangeAreDropped() = fixture {
        val task = store.createTask(listId = work.id, title = "Odd", estimateSeconds = 0, priority = 7)
        assertNull(task.estimateSeconds)
        assertNull(store.taskEditorMetadata(task.id).priority)
    }

    @Test
    fun aTypedTaskIsOneUndoStep() = fixture {
        val task = store.createTask(
            listId = work.id, title = "Write notes", kanbanColumn = NextUpSelector.todayColumnID,
            estimateSeconds = 600, tags = listOf("work"),
        )
        assertEquals("New Task", store.undo())
        assertNull(store.task(task.id))
    }

    @Test
    fun planningPutsATaskOnTodayAndTakingItOffRemovesIt() = fixture {
        val task = store.createTask(listId = work.id, title = "Report")
        assertEquals(emptyList<String>(), plannedOrder())
        store.setPlannedForToday(true, listOf(task.id))
        assertEquals(listOf(task.id), plannedOrder())
        assertEquals(NextUpSelector.todayColumnID, store.kanbanColumn(task.id))
        store.setPlannedForToday(false, listOf(task.id))
        assertEquals(emptyList<String>(), plannedOrder())
        assertNull(store.kanbanColumn(task.id))
    }

    @Test
    fun planningWhatIsAlreadyPlannedIsNotAnUndoStep() = fixture {
        val task = store.createTask(listId = work.id, title = "Report", kanbanColumn = NextUpSelector.todayColumnID)
        store.setPlannedForToday(true, listOf(task.id))
        assertEquals("New Task", store.undoableLabel())
    }

    @Test
    fun arrangingTheDayOrdersItAcrossLists() = fixture {
        val report = store.createTask(listId = work.id, title = "Report")
        val laundry = store.createTask(listId = home.id, title = "Laundry")
        val email = store.createTask(listId = work.id, title = "Email")
        store.setPlannedForToday(true, listOf(report.id, laundry.id, email.id))
        store.arrangeDay(listOf(email.id, laundry.id, report.id))
        assertEquals(listOf(email.id, laundry.id, report.id), plannedOrder())
        assertEquals("Reorder Today", store.undo())
        assertNotEquals(email.id, plannedOrder().first())
    }

    @Test
    fun takingATaskOffTodayDropsItsPlace() = fixture {
        val report = store.createTask(listId = work.id, title = "Report")
        val email = store.createTask(listId = work.id, title = "Email")
        store.setPlannedForToday(true, listOf(report.id, email.id))
        store.arrangeDay(listOf(email.id, report.id))
        store.setPlannedForToday(false, listOf(email.id))
        assertEquals(listOf(report.id), plannedOrder())
        store.setPlannedForToday(true, listOf(email.id))
        assertEquals(listOf(report.id, email.id), plannedOrder())
    }
}
