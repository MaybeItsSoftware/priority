package uk.co.maybeitsadam.takt.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The schedule parts of `TaktDailiesTests.swift` (DailyModelTests, DailyCollectionTests). */
class TaktDailiesTest {
    /** 2026-08-14 is a Friday, 2026-08-15 a Saturday. */
    private fun d(year: Int, month: Int, day: Int, hour: Int = 10) = date(year, month, day, hour)

    @Test fun anEveryDayDailyIsDueOnAWeekend() {
        assertTrue(Daily(title = "Stretch").isDue(d(2026, 8, 15), UTC))
    }

    @Test fun aWeekdaysDailyIsNotDueOnSaturday() {
        val daily = Daily(title = "Standup", activeWeekdays = Daily.MONDAY_TO_FRIDAY)
        assertTrue(daily.isDue(d(2026, 8, 14), UTC))
        assertFalse(daily.isDue(d(2026, 8, 15), UTC))
    }

    @Test fun anArchivedDailyIsNeverDue() {
        assertFalse(Daily(title = "Old habit", archivedAt = d(2026, 8, 1)).isDue(d(2026, 8, 14), UTC))
    }

    @Test fun anEmptyWeekdaySetFallsBackToEveryDay() {
        assertEquals(Daily.ALL_WEEKDAYS, Daily(title = "Anything", activeWeekdays = emptySet()).activeWeekdays)
    }

    @Test fun scheduleLabelNamesTheCommonCases() {
        assertEquals("Every day", Daily(title = "A").scheduleLabel)
        assertEquals("Weekdays", Daily(title = "B", activeWeekdays = Daily.MONDAY_TO_FRIDAY).scheduleLabel)
        assertEquals("Mon Wed", Daily(title = "C", activeWeekdays = setOf(2, 4)).scheduleLabel)
        assertEquals("Weekends", Daily(title = "D", activeWeekdays = Daily.WEEKEND).scheduleLabel)
    }

    @Test fun anIntervalDailyIsDueEveryNthDayRegardlessOfWeekday() {
        val daily = Daily(title = "Water the plants")
        daily.setSchedule(Daily.Schedule.EveryNDays(3), d(2026, 8, 14))
        assertTrue(daily.isDue(d(2026, 8, 14), UTC))
        assertFalse(daily.isDue(d(2026, 8, 15), UTC))
        assertFalse(daily.isDue(d(2026, 8, 16), UTC))
        assertTrue(daily.isDue(d(2026, 8, 17), UTC))
        assertTrue(daily.isDue(d(2026, 8, 20), UTC))
    }

    @Test fun theCycleExtendsBackwardsFromTheAnchor() {
        val daily = Daily(title = "Bins")
        daily.setSchedule(Daily.Schedule.EveryNDays(2), d(2026, 8, 14))
        assertTrue(daily.isDue(d(2026, 8, 12), UTC))
        assertFalse(daily.isDue(d(2026, 8, 13), UTC))
    }

    @Test fun duenessIgnoresTheTimeOfDayWithinEachDay() {
        val daily = Daily(title = "Long run")
        daily.setSchedule(Daily.Schedule.EveryNDays(2), d(2026, 8, 14, 22))
        assertTrue(daily.isDue(d(2026, 8, 16, 9), UTC))
        assertFalse(daily.isDue(d(2026, 8, 17, 9), UTC))
    }

    @Test fun anEveryOneDayCycleIsJustEveryDay() {
        val daily = Daily(title = "Stretch")
        daily.setSchedule(Daily.Schedule.EveryNDays(1), d(2026, 8, 14))
        assertTrue(daily.isEveryDay)
        assertTrue(daily.isDue(d(2026, 8, 15), UTC))
        assertEquals("Every day", daily.scheduleLabel)
    }

    @Test fun anArchivedIntervalDailyIsStillNeverDue() {
        val daily = Daily(title = "Old cycle", archivedAt = d(2026, 8, 1))
        daily.setSchedule(Daily.Schedule.EveryNDays(2), d(2026, 8, 14))
        assertFalse(daily.isDue(d(2026, 8, 14), UTC))
    }

    @Test fun intervalScheduleLabels() {
        assertEquals("Every other day", Daily.scheduleLabel(Daily.Schedule.EveryNDays(2)))
        assertEquals("Every 3 days", Daily.scheduleLabel(Daily.Schedule.EveryNDays(3)))
        assertEquals("Weekdays", Daily.scheduleLabel(Daily.Schedule.Weekdays(Daily.MONDAY_TO_FRIDAY)))
    }

    @Test fun anAbsurdIntervalIsClampedRatherThanHonoured() {
        assertEquals(1, Daily(title = "A", intervalDays = 0).intervalDays)
        assertEquals(366, Daily(title = "B", intervalDays = 10_000).intervalDays)
    }

    @Test fun switchingToACycleAndBackKeepsTheWeekdaySet() {
        val daily = Daily(title = "Gym", activeWeekdays = setOf(2, 4, 6))
        daily.setSchedule(Daily.Schedule.EveryNDays(3), d(2026, 8, 14))
        assertEquals(setOf(2, 4, 6), daily.activeWeekdays)
        daily.setSchedule(Daily.Schedule.Weekdays(daily.activeWeekdays))
        assertNull(daily.intervalDays)
        assertNull(daily.intervalAnchor)
        assertEquals("Mon Wed Fri", daily.scheduleLabel)
    }

    @Test fun changingTheIntervalKeepsTheExistingAnchor() {
        val daily = Daily(title = "Bins")
        daily.setSchedule(Daily.Schedule.EveryNDays(2), d(2026, 8, 14))
        daily.setSchedule(Daily.Schedule.EveryNDays(4), d(2026, 8, 20))
        assertEquals(d(2026, 8, 14), daily.intervalAnchor)
        assertTrue(daily.isDue(d(2026, 8, 18), UTC))
    }

    @Test fun aDailyWithoutAnIntervalIsUnchanged() {
        val daily = Daily(title = "Standup", activeWeekdays = Daily.MONDAY_TO_FRIDAY)
        assertNull(daily.intervalDays)
        assertEquals(Daily.Schedule.Weekdays(Daily.MONDAY_TO_FRIDAY), daily.schedule)
        assertFalse(daily.isDue(d(2026, 8, 15), UTC))
    }

    // DailyCollectionTests

    @Test fun addAssignsAnIncreasingSortIndex() {
        val c = DailyCollection()
        c.add(Daily(title = "First"))
        c.add(Daily(title = "Second"))
        assertEquals(listOf("First", "Second"), c.active.map { it.title })
        assertEquals(listOf(0, 1), c.active.map { it.sortIndex })
    }

    @Test fun archivingKeepsTheRecordButDropsItFromActive() {
        val c = DailyCollection()
        c.add(Daily(id = "a", title = "Gone"))
        c.archive("a")
        assertTrue(c.active.isEmpty())
        assertEquals("Gone", c.daily("a")?.title)
    }

    @Test fun restoringPutsAnArchivedDailyBack() {
        val c = DailyCollection()
        c.add(Daily(id = "a", title = "Back again"))
        c.archive("a")
        c.restore("a")
        assertEquals(listOf("a"), c.active.map { it.id })
        assertNull(c.daily("a")?.archivedAt)
    }

    @Test fun restoringKeepsThePositionItHad() {
        val c = DailyCollection()
        c.add(Daily(id = "a", title = "First"))
        c.add(Daily(id = "b", title = "Second"))
        c.add(Daily(id = "c", title = "Third"))
        c.archive("b")
        assertEquals(listOf("a", "c"), c.active.map { it.id })
        c.restore("b")
        assertEquals(listOf("a", "b", "c"), c.active.map { it.id })
    }

    @Test fun anArchivedDailyIsNotDueAndARestoredOneIs() {
        val c = DailyCollection()
        c.add(Daily(id = "a", title = "Every day"))
        val today = d(2026, 8, 18)
        c.archive("a")
        assertTrue(c.due(today, UTC).isEmpty())
        c.restore("a")
        assertEquals(listOf("a"), c.due(today, UTC).map { it.id })
    }

    @Test fun dueFiltersBySchedule() {
        val c = DailyCollection()
        c.add(Daily(id = "a", title = "Every day"))
        c.add(Daily(id = "b", title = "Weekdays", activeWeekdays = Daily.MONDAY_TO_FRIDAY))
        assertEquals(listOf("a"), c.due(d(2026, 8, 15), UTC).map { it.id })
    }

    @Test fun dueFiltersByRotatingSchedule() {
        val c = DailyCollection()
        val rotating = Daily(id = "a", title = "Every third day")
        rotating.setSchedule(Daily.Schedule.EveryNDays(3), d(2026, 8, 15))
        c.add(rotating)
        c.add(Daily(id = "b", title = "Every day"))
        assertEquals(listOf("a", "b"), c.due(d(2026, 8, 15), UTC).map { it.id })
        assertEquals(listOf("b"), c.due(d(2026, 8, 16), UTC).map { it.id })
        assertEquals(listOf("a", "b"), c.due(d(2026, 8, 18), UTC).map { it.id })
    }

    @Test fun moveReordersAndRenumbers() {
        val c = DailyCollection()
        c.add(Daily(id = "a", title = "A"))
        c.add(Daily(id = "b", title = "B"))
        c.add(Daily(id = "c", title = "C"))
        c.move("c", -2)
        assertEquals(listOf("c", "a", "b"), c.active.map { it.id })
        assertEquals(listOf(0, 1, 2), c.active.map { it.sortIndex })
    }

    @Test fun movingPastTheEndClampsRatherThanWrapping() {
        val c = DailyCollection()
        c.add(Daily(id = "a", title = "A"))
        c.add(Daily(id = "b", title = "B"))
        c.move("a", 99)
        assertEquals(listOf("b", "a"), c.active.map { it.id })
    }
}
