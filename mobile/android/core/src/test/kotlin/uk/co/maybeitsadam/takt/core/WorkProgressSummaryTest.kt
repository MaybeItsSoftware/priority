package uk.co.maybeitsadam.takt.core

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.Instant

class WorkProgressSummaryTest {
    /** Wednesday 2025-09-24, mid-afternoon; Monday-first week. */
    private val now = epoch(1_758_726_000)
    private fun day(offset: Int, hour: Int = 10): Instant = startOfDay(now).atZone(UTC).plusDays(offset.toLong()).plusHours(hour.toLong()).toInstant()
    private fun summarise(completions: List<Instant>, blocks: List<WorkBlockTime>) =
        WorkProgressSummary.summarise(completions, blocks, now, UTC, firstWeekday = 2)

    @Test fun separatesTodayFromTheRestOfTheWeek() {
        val progress = summarise(
            listOf(day(0), day(0, 14), day(-1), day(-2)),
            listOf(WorkBlockTime(1_800, day(0)), WorkBlockTime(900, day(0, 13)), WorkBlockTime(3_600, day(-1))),
        )
        assertEquals(WorkTotals(2, 2_700), progress.today)
        assertEquals(WorkTotals(4, 6_300), progress.week)
    }

    @Test fun weekStopsAtTheStartOfTheUsersWeek() {
        val progress = summarise(listOf(day(-3)), listOf(WorkBlockTime(7_200, day(-3))))
        assertEquals(WorkTotals.ZERO, progress.week)
        assertEquals(3, progress.elapsedDays)
    }

    @Test fun tomorrowsWorkIsNotCountedToday() {
        val progress = summarise(listOf(day(1)), listOf(WorkBlockTime(600, day(1))))
        assertEquals(WorkTotals.ZERO, progress.today)
        assertEquals(WorkTotals.ZERO, progress.week)
    }

    @Test fun paceComparesTodayWithTheWeeksOwnAverage() {
        val progress = summarise(
            emptyList(),
            listOf(WorkBlockTime(3_600, day(-2)), WorkBlockTime(3_600, day(-1)), WorkBlockTime(3_600, day(0))),
        )
        assertEquals(3, progress.elapsedDays)
        assertEquals(3_600, progress.averageSecondsPerDay)
        assertEquals(1.0, progress.paceAgainstWeek, 0.001)
        assertEquals(1.0 / 3.0, progress.shareOfWeek, 0.001)
    }

    @Test fun anEmptyWeekHasNoPaceRatherThanADivisionByZero() {
        val progress = summarise(emptyList(), emptyList())
        assertEquals(0, progress.averageSecondsPerDay)
        assertEquals(0.0, progress.paceAgainstWeek, 0.0)
        assertEquals(0.0, progress.shareOfWeek, 0.0)
    }

    @Test fun negativeBlockSecondsCannotSubtractFromTheDay() {
        val progress = summarise(emptyList(), listOf(WorkBlockTime(600, day(0)), WorkBlockTime(-600, day(0))))
        assertEquals(600, progress.today.seconds)
    }
}
