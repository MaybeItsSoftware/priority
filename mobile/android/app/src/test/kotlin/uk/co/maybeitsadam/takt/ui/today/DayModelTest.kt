package uk.co.maybeitsadam.takt.ui.today

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.T0
import uk.co.maybeitsadam.takt.core.DayPlanEntry
import uk.co.maybeitsadam.takt.core.DayPlanReason
import uk.co.maybeitsadam.takt.core.FocusRanking
import uk.co.maybeitsadam.takt.core.NextUpCandidate
import uk.co.maybeitsadam.takt.core.NextUpReason
import uk.co.maybeitsadam.takt.core.ScoredNextUp
import uk.co.maybeitsadam.takt.core.WorkProgress
import uk.co.maybeitsadam.takt.core.WorkspaceNextUpSnapshot
import uk.co.maybeitsadam.takt.session
import uk.co.maybeitsadam.takt.task

class DayModelTest {
    private fun card(
        id: String,
        reason: DayPlanReason? = DayPlanReason.PLANNED,
        estimate: Int? = null,
        logged: Int = 0,
        running: Boolean = false,
        dailyDone: Boolean = false,
    ) = DayCard(id, id, null, null, reason, estimate, logged, null, false, if (dailyDone) "D" else null, dailyDone, running)

    private fun snapshot(plan: List<DayPlanEntry>, ranked: List<String> = emptyList(), logged: Map<String, Int> = emptyMap()) =
        WorkspaceNextUpSnapshot(
            loggedSeconds = logged, planning = emptyMap(), conditions = emptyList(), todayPlan = plan,
            workProgress = WorkProgress.EMPTY,
            ranking = FocusRanking(ranked.map { ScoredNextUp(NextUpCandidate(it, it), 0.0, NextUpReason.ORDER) }, emptyList(), null),
            dayTasks = (plan.map { it.id } + ranked).associateWith { task(it, estimate = 1800) },
            hasManualFocusOrder = false,
        )

    @Test fun forecastAddsRemainingToNow() {
        val f = DayShaping.forecast(listOf(card("a", estimate = 3600, logged = 600), card("b", estimate = 1800), card("c")), null, T0)
        assertEquals(5400, f.estimatedSeconds)
        assertEquals(600, f.loggedSeconds)
        assertEquals(4800, f.remainingSeconds)
        assertEquals(1, f.unestimatedCount)
        assertEquals(T0.plusSeconds(4800), f.finishAt)
        assertEquals("10m of 1h 30m", f.spentText)
        assertEquals("1h 20m left · 1 unestimated", f.remainingText)
    }

    @Test fun overrunOwesNothingAndNoFinish() {
        val f = DayShaping.forecast(listOf(card("a", estimate = 600, logged = 900)), null, T0)
        assertEquals(0, f.remainingSeconds)
        assertNull(f.finishAt)
        assertEquals("Every estimate used up", f.remainingText)
    }

    @Test fun runningBlockElapsedCountsAndDoneDailiesDoNot() {
        val s = session("a", startedAt = T0, accumulated = 300)
        val cards = listOf(card("a", estimate = 3600, running = true), card("d", estimate = 600, dailyDone = true))
        val f = DayShaping.forecast(cards, s, T0.plusSeconds(600))
        assertEquals(900, f.loggedSeconds)
        assertEquals(2700, f.remainingSeconds)
    }

    @Test fun noEstimatesMeansNoFinish() {
        val f = DayForecast.of(emptyList(), T0)
        assertEquals("No estimates yet", f.remainingText)
        assertEquals("0m logged", f.spentText)
    }

    @Test fun sectionsFollowReasonOrderWithRunningFirst() {
        val sections = DayShaping.sections(
            listOf(
                card("o", DayPlanReason.OVERDUE), card("p1"), card("r", running = true), card("p2"),
                card("s", DayPlanReason.STARTS_TODAY),
            ),
        )
        assertEquals(
            listOf(DaySectionKind.RUNNING, DaySectionKind.PLANNED, DaySectionKind.OVERDUE, DaySectionKind.STARTS_TODAY),
            sections.map { it.kind },
        )
        assertEquals(listOf("p1", "p2"), sections[1].cards.map { it.id })
    }

    @Test fun buildUsesPlanOrFallsBackToRanking() {
        val plan = listOf(DayPlanEntry("a", DayPlanReason.PLANNED), DayPlanEntry("b", DayPlanReason.OVERDUE))
        val planned = DayShaping.build(snapshot(plan, logged = mapOf("a" to 60)), session("a"), emptyList(), emptyList())
        assertTrue(planned.isPlanned)
        assertEquals(listOf("a", "b"), planned.cards.map { it.id })
        assertTrue(planned.cards[0].isRunning)
        assertEquals(60, planned.cards[0].loggedSeconds)
        val fallback = DayShaping.build(snapshot(emptyList(), ranked = (1..10).map { "t$it" }), null, emptyList(), emptyList())
        assertFalse(fallback.isPlanned)
        assertEquals(WorkspaceNextUpSnapshot.fallbackDayLength, fallback.cards.size)
        assertEquals(DaySectionKind.RANKED, fallback.sections.single().kind)
    }

    @Test fun arrangementMovesOnlyWithinBounds() {
        assertEquals(listOf("b", "a", "c"), DayArrangement.moving("a", 1, listOf("a", "b", "c")))
        assertNull(DayArrangement.moving("a", -1, listOf("a", "b")))
        assertNull(DayArrangement.moving("x", 1, listOf("a", "b")))
        val cards = listOf(card("a"), card("o", DayPlanReason.OVERDUE), card("b"))
        assertEquals(listOf("b", "o", "a"), DayArrangement.applying(listOf("b", "a"), cards).map { it.id })
    }

    @Test fun dailyProgressText() {
        assertEquals("20m/30m", DayDaily("d", "t", "x", false, 1200, 1800).progressText)
        assertNull(DayDaily("d", "t", "x", false, 0, null).progressText)
    }
}
