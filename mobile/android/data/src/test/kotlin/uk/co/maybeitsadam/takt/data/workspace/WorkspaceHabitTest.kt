package uk.co.maybeitsadam.takt.data.workspace

import java.time.LocalDateTime
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.core.HabitExpiry
import uk.co.maybeitsadam.takt.core.HabitFrequency
import uk.co.maybeitsadam.takt.core.HabitPlacement
import uk.co.maybeitsadam.takt.core.HabitPolicy
import uk.co.maybeitsadam.takt.core.TaskList
import uk.co.maybeitsadam.takt.core.TaskStatus
import uk.co.maybeitsadam.takt.core.Workspace
import uk.co.maybeitsadam.takt.data.TestWorkspace

/** Port of workspace-tests/WorkspaceHabitTests.swift. 2026-10-05 is a Monday. */
class WorkspaceHabitTest {
    private class Fixture(val w: TestWorkspace, val workspace: Workspace, val list: TaskList) {
        val store get() = w.repository
    }

    private fun fixture(test: suspend Fixture.() -> Unit): Unit = runBlocking {
        workspace().use { w ->
            val workspace = w.repository.bootstrapIfNeeded()
            Fixture(w, workspace, w.repository.lists(workspace.id).first()).test()
        }
    }

    private fun day(value: Int, hour: Int = 12) = LocalDateTime.of(2026, 10, value, hour, 0).atZone(UTC).toInstant()

    @Test
    fun theFormOpensOnTheSelectedTaskAsASourceOrOnItsHabit() = fixture {
        val goal = store.createTask(listId = list.id, title = "Learn drums")
        val fresh = store.habitFormContext(goal.id)
        assertNull(fresh.habitTaskId)
        assertEquals(goal.id, fresh.draft.sourceTaskId)
        assertEquals(HabitExpiry.WhenSourceCompleted, fresh.draft.expiry)
        assertEquals("Learn drums", fresh.sourceTitle)

        assertEquals(HabitExpiry.Never, store.habitFormContext(null).draft.expiry)

        val draft = fresh.draft.copy(
            title = "Practise drums", frequency = HabitFrequency.Weekdays(setOf(2, 4, 6)), estimateSeconds = 1_800,
            placement = HabitPlacement.THIS_WEEK, dropsAtDayEnd = false,
        )
        val daily = store.saveHabit(draft, now = day(5), zone = UTC)

        val editing = store.habitFormContext(daily.taskId)
        assertEquals(daily.taskId, editing.habitTaskId)
        assertEquals(draft, editing.draft)
        assertEquals("Learn drums", editing.sourceTitle)
        assertEquals(1_800, store.task(daily.taskId)?.estimateSeconds)
        // The new habit lives in the Habits list, whose id the Mac derives too.
        val habits = store.task(daily.taskId)!!.listId
        assertEquals(HabitPolicy.habitsListId(workspace.id), habits)
        assertEquals(setOf(daily.taskId), store.habitTaskIds())
    }

    @Test
    fun aDueHabitLandsInItsColumnAndLeavesItOnceTicked() = fixture {
        val daily = store.saveHabit(HabitDraft("Stretch", placement = HabitPlacement.THIS_WEEK), now = day(5), zone = UTC)
        assertEquals("this-week", store.kanbanColumn(daily.taskId))

        store.logContribution(dailyId = daily.id, now = day(5), zone = UTC)
        assertTrue(store.reconcileHabits(now = day(5, hour = 13), zone = UTC))
        assertNull(store.kanbanColumn(daily.taskId))

        assertTrue(store.reconcileHabits(now = day(6), zone = UTC))
        assertEquals("this-week", store.kanbanColumn(daily.taskId))
        assertEquals(TaskStatus.OPEN, store.task(daily.taskId)?.status)
    }

    @Test
    fun aMissedAppearanceIsDroppedOrCarried() = fixture {
        val dropped = store.saveHabit(
            HabitDraft("Weekly review", frequency = HabitFrequency.Weekly, dropsAtDayEnd = true), now = day(5), zone = UTC,
        )
        val carried = store.saveHabit(
            HabitDraft("Call home", frequency = HabitFrequency.Weekly, dropsAtDayEnd = false, placement = HabitPlacement.WAITING),
            now = day(5), zone = UTC,
        )

        store.reconcileHabits(now = day(7), zone = UTC)

        assertNull(store.kanbanColumn(dropped.taskId))
        assertEquals("waiting-on", store.kanbanColumn(carried.taskId))
        assertEquals(listOf(carried.id), store.dailies(day(7), UTC).map { it.daily.id })
    }

    @Test
    fun completingTheSourceTaskEndsTheHabitAndUndoBringsItBack() = fixture {
        val goal = store.createTask(listId = list.id, title = "Learn drums")
        val draft = store.habitFormContext(goal.id).draft.copy(title = "Practise drums")
        val daily = store.saveHabit(draft)
        assertEquals("today", store.kanbanColumn(daily.taskId))

        store.setStatus(TaskStatus.COMPLETED, goal.id)

        assertNull("the habit ended with its source", store.daily(daily.taskId))
        assertNull(store.kanbanColumn(daily.taskId))

        assertEquals("Change Status", store.undo())
        assertEquals(daily.id, store.daily(daily.taskId)?.id)
    }

    @Test
    fun aDateExpiryArchivesTheHabitOnThatDay() = fixture {
        val daily = store.saveHabit(HabitDraft("Course reading", expiry = HabitExpiry.On(day(8))), now = day(5), zone = UTC)

        store.reconcileHabits(now = day(7), zone = UTC)
        assertNotNull(store.daily(daily.taskId))

        store.reconcileHabits(now = day(8), zone = UTC)
        assertNull(store.daily(daily.taskId))
        assertNull(store.kanbanColumn(daily.taskId))
    }

    @Test
    fun aCardMovedByHandIsLeftWhereItWasPut() = fixture {
        val daily = store.saveHabit(HabitDraft("Stretch"), now = day(5), zone = UTC)
        store.setKanbanColumn("in-progress", daily.taskId)

        assertFalse(store.reconcileHabits(now = day(6), zone = UTC))
        assertEquals("in-progress", store.kanbanColumn(daily.taskId))
    }

    @Test
    fun aSecondHabitReusesTheHabitsListAndAPlainDailyIsLeftAlone() = fixture {
        val first = store.saveHabit(HabitDraft("Stretch"), now = day(5), zone = UTC)
        val second = store.saveHabit(HabitDraft("Read"), now = day(5), zone = UTC)
        assertEquals(store.task(first.taskId)?.listId, store.task(second.taskId)?.listId)
        assertEquals(1, store.lists(workspace.id).count { it.name == "Habits" })

        val plain = store.createTask(listId = list.id, title = "Write")
        store.makeDaily(plain.id)
        store.reconcileHabits(now = day(6), zone = UTC)
        assertNull(store.kanbanColumn(plain.id))
    }
}
