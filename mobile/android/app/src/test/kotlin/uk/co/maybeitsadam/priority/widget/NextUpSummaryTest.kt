package uk.co.maybeitsadam.priority.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.priority.core.DayPlanEntry
import uk.co.maybeitsadam.priority.core.DayPlanReason
import uk.co.maybeitsadam.priority.core.FocusRanking
import uk.co.maybeitsadam.priority.core.NextUpCandidate
import uk.co.maybeitsadam.priority.core.NextUpReason
import uk.co.maybeitsadam.priority.core.ScoredNextUp
import uk.co.maybeitsadam.priority.core.WorkProgress
import uk.co.maybeitsadam.priority.core.WorkspaceNextUpSnapshot
import uk.co.maybeitsadam.priority.task

class NextUpSummaryTest {
    private fun snapshot(plan: List<DayPlanEntry>, ranked: List<String>) = WorkspaceNextUpSnapshot(
        emptyMap(), emptyMap(), emptyList(), plan, WorkProgress.EMPTY,
        FocusRanking(ranked.map { ScoredNextUp(NextUpCandidate(it, it), 0.0, NextUpReason.DUE_TODAY) }, emptyList(), null),
        (plan.map { it.id } + ranked).associateWith { task(it, title = "T $it") }, false,
    )

    @Test fun runningThenPlanThenRanking() {
        val plan = listOf(DayPlanEntry("p", DayPlanReason.PLANNED), DayPlanEntry("o", DayPlanReason.OVERDUE))
        val running = NextUpSummary.of(snapshot(plan, listOf("r")), "o")
        assertTrue(running.isRunning)
        assertEquals("T o", running.title)
        assertEquals(NextUpSummary("p", "T p", "Planned", 2, false), NextUpSummary.of(snapshot(plan, listOf("r")), null))
        assertEquals(NextUpSummary("r", "T r", "It is due today", 0, false), NextUpSummary.of(snapshot(emptyList(), listOf("r")), null))
        assertEquals(NextUpSummary.EMPTY, NextUpSummary.of(snapshot(emptyList(), emptyList()), null))
    }
}
