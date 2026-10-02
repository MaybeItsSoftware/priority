package uk.co.maybeitsadam.priority.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

class CompletedWorkDigestTest {
    /** Wednesday 2025-09-24, mid-afternoon. */
    private val now = epoch(1_758_726_000)
    private fun day(offset: Int, hour: Int = 10): Instant = startOfDay(now).atZone(UTC).plusDays(offset.toLong()).plusHours(hour.toLong()).toInstant()

    private data class Item(val name: String, val at: Instant)
    private fun group(items: List<Item>) = CompletedWorkDigest.group(items, { it.at }, now, UTC)

    @Test fun daysComeBackNewestFirst() {
        val groups = group(listOf(Item("old", day(-3)), Item("now", day(0)), Item("mid", day(-1))))
        assertEquals(listOf("now", "mid", "old"), groups.map { it.items.first().name })
    }

    @Test fun oneDaysItemsComeBackNewestFirst() {
        val groups = group(listOf(Item("morning", day(0, 9)), Item("evening", day(0, 21)), Item("lunch", day(0, 13))))
        assertEquals(1, groups.size)
        assertEquals(listOf("evening", "lunch", "morning"), groups[0].items.map { it.name })
    }

    @Test fun lateLastNightIsYesterdayNotToday() {
        val groups = group(listOf(Item("late", day(-1, 23)), Item("early", day(0, 1))))
        assertEquals(listOf(CompletedWorkDayKind.TODAY, CompletedWorkDayKind.YESTERDAY), groups.map { it.kind })
        assertEquals(listOf("early", "late"), groups.map { it.items.first().name })
    }

    @Test fun theWeekEndsAtSixDaysSoAWeekdayNameStaysUnambiguous() {
        assertEquals(CompletedWorkDayKind.TODAY, CompletedWorkDigest.kind(day(0), now, UTC))
        assertEquals(CompletedWorkDayKind.YESTERDAY, CompletedWorkDigest.kind(day(-1), now, UTC))
        assertEquals(CompletedWorkDayKind.THIS_WEEK, CompletedWorkDigest.kind(day(-2), now, UTC))
        assertEquals(CompletedWorkDayKind.THIS_WEEK, CompletedWorkDigest.kind(day(-6), now, UTC))
        assertEquals(CompletedWorkDayKind.EARLIER, CompletedWorkDigest.kind(day(-7), now, UTC))
    }

    @Test fun somethingDatedLaterTodayIsStillToday() {
        assertEquals(CompletedWorkDayKind.TODAY, CompletedWorkDigest.kind(day(1), now, UTC))
    }

    @Test fun nothingFinishedIsNoDays() {
        assertTrue(group(emptyList()).isEmpty())
    }
}
