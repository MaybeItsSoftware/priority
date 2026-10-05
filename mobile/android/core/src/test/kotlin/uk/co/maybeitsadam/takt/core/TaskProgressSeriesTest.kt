package uk.co.maybeitsadam.takt.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId

class TaskProgressSeriesTest {
    private val london: ZoneId = ZoneId.of("Europe/London")
    private fun d(day: Int, hour: Int = 12, month: Int = 3) = date(2026, month, day, hour, zone = london)
    private fun sod(i: java.time.Instant) = startOfDay(i, london)

    @Test fun everyDayOfThePeriodIsPresentEmptyOnesIncluded() {
        val series = TaskProgressSeries.build(TaskProgressPeriod.WEEK, emptyList(), emptyList(), d(20), london)
        assertEquals(7, series.days.size)
        assertEquals(sod(d(14)), series.days.first().dayStart)
        assertEquals(sod(d(20)), series.days.last().dayStart)
        assertTrue(series.days.all { it.completed == 0 && it.added == 0 })
    }

    @Test fun countsCompletionsAndCreationsPerDayWithARunningTotal() {
        val series = TaskProgressSeries.build(
            TaskProgressPeriod.WEEK,
            completions = listOf(d(15, 9), d(15, 23), d(18, 0)),
            creations = listOf(d(15), d(19), d(19), d(20)),
            now = d(20, 8), zone = london,
        )
        assertEquals(listOf(0, 2, 0, 0, 1, 0, 0), series.days.map { it.completed })
        assertEquals(listOf(0, 1, 0, 0, 0, 2, 1), series.days.map { it.added })
        assertEquals(listOf(0, 2, 2, 2, 3, 3, 3), series.days.map { it.cumulativeCompleted })
        assertEquals(3, series.totalCompleted)
        assertEquals(4, series.totalAdded)
        assertEquals(-1, series.net)
        assertEquals(sod(d(15)), series.bestDay?.dayStart)
    }

    @Test fun timesOutsideThePeriodAreIgnoredNotClamped() {
        val series = TaskProgressSeries.build(TaskProgressPeriod.WEEK, listOf(d(13, 23), d(21, 0)), listOf(d(1)), d(20), london)
        assertEquals(0, series.totalCompleted)
        assertEquals(0, series.totalAdded)
        assertNull(series.bestDay)
    }

    @Test fun theIntervalRunsFromTheFirstDaysStartToTheEndOfToday() {
        val interval = TaskProgressSeries.interval(TaskProgressPeriod.MONTH, d(20, 15), london)
        assertEquals(sod(d(20).atZone(london).minusDays(29).toInstant()), interval.start)
        assertEquals(sod(d(21)), interval.end)
    }

    @Test fun aDaylightSavingChangeStillGivesOneBucketPerDay() {
        val series = TaskProgressSeries.build(TaskProgressPeriod.WEEK, listOf(d(29, 3)), emptyList(), d(1, 12, month = 4), london)
        assertEquals(7, series.days.size)
        assertEquals(7, series.days.map { it.dayStart }.toSet().size)
        assertEquals(1, series.totalCompleted)
    }
}
