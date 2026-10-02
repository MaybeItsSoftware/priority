package uk.co.maybeitsadam.priority.core

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.Instant

class DayPlanSelectorTest {
    /** Midday. */
    private val now = epoch(1_750_075_200)

    private fun candidate(
        id: String,
        due: Instant? = null,
        dueDate: String? = null,
        start: Instant? = null,
        column: String? = null,
        order: Int = 0,
        rank: Int? = null,
    ) = NextUpCandidate(id = id, title = id, dueAt = due, startAt = start, kanbanColumn = column, focusRank = rank, sortOrder = order, dueDate = dueDate)

    private fun plan(candidates: List<NextUpCandidate>, running: String? = null) =
        DayPlanSelector.plan(candidates, runningID = running, now = now, zone = UTC)

    @Test fun theTodayColumnIsTheDay() {
        val entries = plan(listOf(candidate("a", column = "today"), candidate("b", column = "backlog")))
        assertEquals(listOf("a"), entries.map { it.id })
        assertEquals(DayPlanReason.PLANNED, entries.first().reason)
    }

    @Test fun deadlinesAndStartsJoinWithoutBeingPlanned() {
        val entries = plan(listOf(
            candidate("planned", column = "today"),
            candidate("due", due = now.plusSeconds(3_600)),
            candidate("late", due = now.minusSeconds(86_400)),
            candidate("starting", start = now.minusSeconds(3_600)),
            candidate("someday"),
        ))
        assertEquals(listOf("planned", "late", "due", "starting"), entries.map { it.id })
        assertEquals(
            listOf(DayPlanReason.PLANNED, DayPlanReason.OVERDUE, DayPlanReason.DUE_TODAY, DayPlanReason.STARTS_TODAY),
            entries.map { it.reason },
        )
    }

    @Test fun tomorrowAndYesterdayAreNotToday() {
        val entries = plan(listOf(
            candidate("tomorrow", due = now.plusSeconds(86_400)),
            candidate("startedYesterday", start = now.minusSeconds(86_400)),
        ))
        assertEquals(emptyList<String>(), entries.map { it.id })
    }

    @Test fun theRunningBlockHeadsTheDayWhereverItCameFrom() {
        val entries = plan(listOf(candidate("planned", column = "today"), candidate("elsewhere")), running = "elsewhere")
        assertEquals(listOf("elsewhere", "planned"), entries.map { it.id })
        assertEquals(DayPlanReason.RUNNING, entries.first().reason)
    }

    @Test fun aTaskIsClaimedOnceByItsStrongestReason() {
        val entries = plan(listOf(candidate("a", due = now.minusSeconds(60), column = "today")))
        assertEquals(1, entries.size)
        assertEquals(DayPlanReason.PLANNED, entries.first().reason)
    }

    @Test fun aHandRankOrdersThePlannedColumn() {
        val entries = plan(listOf(
            candidate("third", column = "today", order = 3),
            candidate("first", column = "today", order = 9, rank = 1),
            candidate("second", column = "today", order = 1),
        ))
        assertEquals(listOf("first", "second", "third"), entries.map { it.id })
    }

    @Test fun aCalendarDueDateCountsAsTheWholeDay() {
        val today = TaskCalendarDate.string(now, UTC)
        assertEquals(listOf(DayPlanReason.DUE_TODAY), plan(listOf(candidate("a", dueDate = today))).map { it.reason })
    }
}
