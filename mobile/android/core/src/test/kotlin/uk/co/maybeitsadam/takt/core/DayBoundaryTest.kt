package uk.co.maybeitsadam.takt.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Duration

/** `DayBoundaryTests` from `TaktDayLogTests.swift`; Gregorian UTC, Sunday-first like the Swift fixture. */
class DayBoundaryTest {
    private fun boundary(hour: Int) = DayBoundary(hour, UTC, firstWeekday = 1)

    @Test fun workAfterMidnightBelongsToThePreviousDay() {
        val b = boundary(4)
        assertEquals("2026-08-14", b.dayKey(date(2026, 8, 15, 1, 30)))
        assertEquals("2026-08-13", b.dayKey(date(2026, 8, 14, 3, 59)))
    }

    @Test fun workAfterRolloverBelongsToTheCurrentDay() {
        val b = boundary(4)
        assertEquals("2026-08-14", b.dayKey(date(2026, 8, 14, 4, 0)))
        assertEquals("2026-08-14", b.dayKey(date(2026, 8, 14, 23, 59)))
    }

    @Test fun midnightRolloverMatchesTheCalendarDay() {
        val b = boundary(0)
        assertEquals("2026-08-15", b.dayKey(date(2026, 8, 15, 0, 1)))
        assertEquals("2026-08-14", b.dayKey(date(2026, 8, 14, 23, 59)))
    }

    @Test fun rolloverHourIsClampedToAValidHour() {
        assertEquals(0, boundary(-5).rolloverHour)
        assertEquals(23, boundary(99).rolloverHour)
    }

    @Test fun logicalDayIsIdempotent() {
        val b = boundary(4)
        val once = b.logicalDay(date(2026, 8, 14, 10))
        assertEquals(once, b.logicalDay(once))
    }

    @Test fun dayKeyOfALogicalDayIsThatSameDay() {
        val b = boundary(4)
        assertEquals("2026-08-14", b.dayKey(b.logicalDay(date(2026, 8, 14, 10))))
    }

    @Test fun dayKeyOfALogicalDayIsStableAtMidnightRollover() {
        val b = boundary(0)
        assertEquals("2026-08-14", b.dayKey(b.logicalDay(date(2026, 8, 14, 10))))
    }

    @Test fun weekStartIsIdempotent() {
        val b = boundary(4)
        val once = b.weekStart(date(2026, 8, 14, 10))
        assertEquals(once, b.weekStart(once))
    }

    @Test fun steppingBackADayAndRekeyingLandsOnYesterday() {
        val b = boundary(4)
        assertEquals("2026-08-13", b.dayKey(b.day(-1, date(2026, 8, 14, 10))))
    }

    @Test fun daysEndingOnProducesAnInclusiveOldestFirstWindow() {
        val b = boundary(4)
        assertEquals(listOf("2026-08-12", "2026-08-13", "2026-08-14"), b.days(date(2026, 8, 14, 10), 3).map { b.dayKey(it) })
    }

    @Test fun daysEndingOnIsEmptyForANonPositiveCount() {
        assertTrue(boundary(4).days(date(2026, 8, 14, 10), 0).isEmpty())
    }

    @Test fun weeksEndingOnStepsBackOneWeekAtATime() {
        val weeks = boundary(4).weeks(date(2026, 8, 14, 10), 3)
        assertEquals(3, weeks.size)
        val gap = Duration.between(weeks[0], weeks[1]).seconds
        assertTrue(kotlin.math.abs(gap - 7 * 24 * 3600) <= 3600)
    }
}
