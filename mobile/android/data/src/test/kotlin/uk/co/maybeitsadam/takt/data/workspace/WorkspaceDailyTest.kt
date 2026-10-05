package uk.co.maybeitsadam.takt.data.workspace

import java.time.LocalDate
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.core.NextUpSelector
import uk.co.maybeitsadam.takt.core.TaskList
import uk.co.maybeitsadam.takt.core.TaskStatus
import uk.co.maybeitsadam.takt.core.Workspace
import uk.co.maybeitsadam.takt.data.TestWorkspace

/**
 * Port of workspace-tests/WorkspaceDailyTests.swift. The Swift calendar is
 * Gregorian in the machine's zone; here it is UTC, the test workspace's zone.
 * `testLegacyDailiesBecomeHabitTasksAndImportingTwiceChangesNothing` is not
 * ported (legacy import).
 */
class WorkspaceDailyTest {
    private class Fixture(val w: TestWorkspace, val workspace: Workspace, val list: TaskList) {
        val store get() = w.repository
    }

    private fun fixture(test: suspend Fixture.() -> Unit): Unit = runBlocking {
        workspace().use { w ->
            val workspace = w.repository.bootstrapIfNeeded()
            Fixture(w, workspace, w.repository.lists(workspace.id).first()).test()
        }
    }

    private fun day(year: Int, month: Int, day: Int) = LocalDate.of(year, month, day).atStartOfDay(UTC).toInstant()

    @Test
    fun makingATaskDailyIsIdempotentAndArchivingLeavesTheTaskAlone() = fixture {
        val task = store.createTask(listId = list.id, title = "Write 500 words")
        val first = store.makeDaily(taskId = task.id)
        val second = store.makeDaily(taskId = task.id)
        assertEquals(first.id, second.id)
        assertEquals(1, store.allDailies().size)
        store.archiveDaily(task.id)
        assertEquals(emptyList<Any>(), store.allDailies())
        assertEquals(TaskStatus.OPEN, store.task(task.id)?.status)
    }

    @Test
    fun tickingADailyLogsAContributionWithoutCompletingTheTask() = fixture {
        val task = store.createTask(listId = list.id, title = "Write 500 words")
        val daily = store.makeDaily(taskId = task.id)
        store.logContribution(dailyId = daily.id, seconds = 1_500)
        val items = store.dailies()
        assertEquals(listOf(task.id), items.map { it.task.id })
        assertTrue(items[0].isDoneToday)
        assertEquals(1_500, items[0].secondsLoggedToday)
        assertEquals(TaskStatus.OPEN, store.task(task.id)?.status)
    }

    @Test
    fun contributionsOnTheSameDayAccumulateIntoOneRow() = fixture {
        val task = store.createTask(listId = list.id, title = "Practice")
        val daily = store.makeDaily(taskId = task.id)
        val noon = epoch(1_750_000_000)
        store.logContribution(dailyId = daily.id, seconds = 600, complete = false, now = noon, zone = UTC)
        store.logContribution(dailyId = daily.id, seconds = 900, complete = true, now = noon.plusSeconds(3_600), zone = UTC)
        val items = store.dailies(day = noon, zone = UTC)
        assertEquals(1_500, items[0].secondsLoggedToday)
        assertTrue(items[0].isDoneToday)
        assertEquals(1, store.contributionHistory(daily.id, days = 2, endingOn = noon, zone = UTC).size)
    }

    @Test
    fun clearingAContributionKeepsTheTimeAlreadyLogged() = fixture {
        val task = store.createTask(listId = list.id, title = "Practice")
        val daily = store.makeDaily(taskId = task.id)
        store.logContribution(dailyId = daily.id, seconds = 900)
        store.clearContribution(daily.id)
        val items = store.dailies()
        assertFalse(items[0].isDoneToday)
        assertEquals(900, items[0].secondsLoggedToday)
    }

    @Test
    fun aWeekdayScheduleOnlyShowsOnItsDays() = fixture {
        val task = store.createTask(listId = list.id, title = "Weekday review")
        store.makeDaily(taskId = task.id, weekdays = setOf(2, 3, 4, 5, 6))
        assertEquals(1, store.dailies(day = day(2025, 6, 16), zone = UTC).size)
        assertEquals(0, store.dailies(day = day(2025, 6, 15), zone = UTC).size)
    }

    @Test
    fun anIntervalScheduleRotatesThroughTheWeek() = fixture {
        val task = store.createTask(listId = list.id, title = "Every third day")
        val anchor = day(2025, 6, 16)
        store.makeDaily(taskId = task.id, intervalDays = 3, now = anchor)
        suspend fun dueCount(offset: Long) = store.dailies(day = anchor.plusSeconds(offset * 86_400), zone = UTC).size
        assertEquals(1, dueCount(0))
        assertEquals(0, dueCount(1))
        assertEquals(1, dueCount(3))
        assertEquals(1, dueCount(6))
    }

    @Test
    fun finishingAFocusBlockOnADailyCreditsTimeInsteadOfCompletingTheTask() = fixture {
        val task = store.createTask(listId = list.id, title = "Write 500 words")
        val daily = store.makeDaily(taskId = task.id)
        val session = store.startFocusSession(taskId = task.id, plannedSeconds = 1_500)
        val completion = store.completeActiveFocusTask(sessionId = session.id, elapsedSeconds = 1_320)
        assertEquals(FocusCompletionOutcome.ContributionLogged(1_320), completion.outcome)
        assertEquals(TaskStatus.OPEN, store.task(task.id)?.status)
        assertEquals(1_320, store.dailies()[0].secondsLoggedToday)
        assertEquals(daily.id, store.daily(task.id)?.id)
    }

    @Test
    fun anEstimateGivenOnTheFocusScreenBecomesTheSessionsWorkBlock() = fixture {
        val task = store.createTask(listId = list.id, title = "Draft proposal")
        val session = store.startFocusSession(taskId = task.id, plannedSeconds = 45 * 60)
        assertEquals(45 * 60, session.workDurationSeconds)
        assertEquals(45 * 60, store.focusQueue(session.id).first().item.plannedSeconds)
    }

    @Test
    fun nextUpKeepsDeadlinePrecedenceAndDropsContributedDailies() = fixture {
        val daily = store.createTask(listId = list.id, title = "Write 500 words")
        val due = store.createTask(listId = list.id, title = "File return")
        store.updateTask(due.id, due.title, "", w.clock.instant, null)
        val record = store.makeDaily(taskId = daily.id)
        val now = w.clock.instant
        assertEquals(due.id, NextUpSelector.next(store.nextUpCandidates(), now, UTC)?.candidate?.id)
        store.logContribution(dailyId = record.id)
        assertFalse(store.nextUpCandidates().any { it.id == daily.id })
        assertEquals(due.id, NextUpSelector.next(store.nextUpCandidates(), w.clock.instant, UTC)?.candidate?.id)
    }

    @Test
    fun nextUpOffersLeavesRatherThanProjectsAndSkipsArchivedLists() = fixture {
        val project = store.createTask(listId = list.id, title = "Ship release")
        val step = store.createTask(listId = list.id, title = "Cut the tag", parentTaskId = project.id)
        val shelved = store.createList(workspaceId = workspace.id, name = "Someday")
        store.createTask(listId = shelved.id, title = "Learn the cello")
        store.setListArchived(true, shelved.id)
        assertEquals(setOf(step.id), store.nextUpCandidates().map { it.id }.toSet())
    }

    @Test
    fun schedulingATaskForLaterRemovesItFromNextUpUntilThatTime() = fixture {
        val task = store.createTask(listId = list.id, title = "Call the bank")
        val later = w.clock.instant.plusSeconds(4 * 3_600)
        store.scheduleTask(task.id, later)
        val stored = store.nextUpCandidates().first().startAt!!
        assertEquals(later.toEpochMilli().toDouble(), stored.toEpochMilli().toDouble(), 1_000.0)
        assertNull(NextUpSelector.next(store.nextUpCandidates(), w.clock.instant, UTC))
        assertEquals(task.id, NextUpSelector.next(store.nextUpCandidates(), later.plusSeconds(60), UTC)?.candidate?.id)
        store.scheduleTask(task.id, null)
        assertEquals(task.id, NextUpSelector.next(store.nextUpCandidates(), w.clock.instant, UTC)?.candidate?.id)
    }

    @Test
    fun theFirstCompletionOfTheDayIsOrdinalOne() = fixture {
        store.createTask(listId = list.id, title = "Anything")
        assertEquals(1, store.completionContext().ordinalToday)
    }

    @Test
    fun ordinalCountsBothFinishedTasksAndTickedDailies() = fixture {
        val done = store.createTask(listId = list.id, title = "Done")
        store.setStatus(TaskStatus.COMPLETED, done.id)
        val habit = store.createTask(listId = list.id, title = "Habit")
        val daily = store.makeDaily(taskId = habit.id)
        store.logContribution(dailyId = daily.id)
        assertEquals(3, store.completionContext().ordinalToday)
    }

    @Test
    fun aStreakCountsBackThroughConsecutiveDaysAndStopsAtAGap() = fixture {
        val habit = store.createTask(listId = list.id, title = "Habit")
        val daily = store.makeDaily(taskId = habit.id)
        val today = w.clock.instant.atZone(UTC).toLocalDate().atStartOfDay(UTC).toInstant()
        for (offset in listOf(1L, 2L, 4L)) {
            store.logContribution(dailyId = daily.id, now = today.minusSeconds(offset * 86_400), zone = UTC)
        }
        assertEquals(3, store.completionContext().streakDays)
    }

    @Test
    fun anEmptyTodayStillCountsBecauseTheCompletionIsAboutToLandOnIt() = fixture {
        assertEquals(1, store.completionContext().streakDays)
    }
}
