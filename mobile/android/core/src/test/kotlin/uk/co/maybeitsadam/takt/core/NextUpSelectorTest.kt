package uk.co.maybeitsadam.takt.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Swift uses the machine's Gregorian calendar here; UTC pins it. */
class NextUpSelectorTest {
    private val now = epoch(1_750_000_000)

    private fun candidate(
        id: String,
        daily: Boolean = false,
        due: Double? = null,
        start: Double? = null,
        urgency: Int? = null,
        importance: Int? = null,
        priority: Int? = null,
        estimate: Int? = null,
        column: String? = null,
        order: Int = 0,
        rank: Int? = null,
    ) = NextUpCandidate(
        id = id, title = id, isDailyDueToday = daily,
        dueAt = due?.let { now.plusSecondsD(it) }, startAt = start?.let { now.plusSecondsD(it) },
        matrixUrgency = urgency, matrixImportance = importance, priority = priority,
        estimateSeconds = estimate, kanbanColumn = column, focusRank = rank, sortOrder = order, createdAt = now,
    )

    private fun rank(candidates: List<NextUpCandidate>) = NextUpSelector.rank(candidates, now, UTC).map { it.candidate.id }

    @Test fun overdueTasksOutrankOutstandingDailies() {
        val ranked = NextUpSelector.rank(
            listOf(
                candidate("overdue", due = -20 * 86_400.0),
                candidate("daily", daily = true),
                candidate("important", urgency = 1, importance = 1, priority = 4),
            ), now, UTC,
        )
        assertEquals(listOf("overdue", "daily", "important"), ranked.map { it.candidate.id })
        assertEquals(NextUpReason.OVERDUE, ranked.first().reason)
    }

    @Test fun overdueBeatsDueTodayAndDeeperOverdueBeatsShallower() {
        assertEquals(
            listOf("later", "late", "today"),
            rank(listOf(candidate("today", due = 0.0), candidate("late", due = -3 * 86_400.0), candidate("later", due = -9 * 86_400.0))),
        )
    }

    @Test fun overdueAgeIsNotCappedAndOlderDeadlinesWin() {
        assertEquals(
            listOf("ancient", "month", "daily"),
            rank(listOf(candidate("month", due = -30 * 86_400.0), candidate("ancient", due = -400 * 86_400.0), candidate("daily", daily = true))),
        )
    }

    @Test fun dueDatesBeyondTheHorizonStopContributing() {
        val far = NextUpSelector.score(candidate("far", due = (NextUpSelector.dueHorizonDays + 40) * 86_400.0), now, UTC)
        val none = NextUpSelector.score(candidate("none"), now, UTC)
        assertEquals(none.score, far.score, 0.0)
        assertEquals(NextUpReason.ORDER, far.reason)
    }

    @Test fun importanceCanOvertakeADistantDueDate() {
        assertEquals(listOf("important", "soon"), rank(listOf(candidate("soon", due = 12 * 86_400.0), candidate("important", urgency = 1, importance = 1))))
    }

    @Test fun todayColumnBeatsBarePriority() {
        assertEquals(listOf("today", "prio"), rank(listOf(candidate("prio", priority = 4), candidate("today", column = "today"))))
    }

    @Test fun tasksScheduledForLaterAreDroppedUntilTheirTimeArrives() {
        assertEquals(listOf("ordinary"), rank(listOf(candidate("later", daily = true, start = 3_600.0), candidate("ordinary"))))
        assertEquals(listOf("due"), rank(listOf(candidate("due", due = 0.0, start = -60.0))))
    }

    @Test fun equalScoresPreferTheShorterJobThenManualOrder() {
        assertEquals(
            listOf("short", "long", "unestimated"),
            rank(listOf(
                candidate("long", priority = 2, estimate = 3_600, order = 0),
                candidate("short", priority = 2, estimate = 600, order = 1),
                candidate("unestimated", priority = 2, order = 2),
            )),
        )
    }

    @Test fun anUntouchedListStillProducesAPickInManualOrder() {
        val pick = NextUpSelector.next(listOf(candidate("second", order = 1), candidate("first", order = 0)), now, UTC)!!
        assertEquals("first", pick.candidate.id)
        assertEquals(NextUpReason.ORDER, pick.reason)
    }

    @Test fun emptyInputHasNoPick() {
        assertNull(NextUpSelector.next(emptyList(), now, UTC))
    }

    @Test fun rankOrdersTheWholeLadderNotJustTheWinner() {
        val ranked = NextUpSelector.rank(
            listOf(
                candidate("order-only", order = 9),
                candidate("daily", daily = true),
                candidate("overdue", due = -2 * 86_400.0),
                candidate("important", urgency = 1, importance = 1),
            ), now, UTC,
        )
        assertEquals(listOf("overdue", "daily", "important", "order-only"), ranked.map { it.candidate.id })
        assertEquals(
            listOf(NextUpReason.OVERDUE, NextUpReason.DAILY, NextUpReason.IMPORTANCE, NextUpReason.ORDER),
            ranked.map { it.reason },
        )
    }

    @Test fun scoresDecreaseMonotonicallyUpTheLadder() {
        val ranked = NextUpSelector.rank(
            listOf(
                candidate("a", daily = true), candidate("b", due = -1 * 86_400.0), candidate("c", due = 0.0),
                candidate("d", column = "today"), candidate("e", priority = 1), candidate("f"),
            ), now, UTC,
        )
        assertEquals(6, ranked.size)
        ranked.zipWithNext().forEach { (higher, lower) ->
            assertTrue("${higher.candidate.id} should outrank ${lower.candidate.id}", higher.score >= lower.score)
        }
    }

    @Test fun handPlacementCannotDisplaceDeadlines() {
        assertEquals(
            "deadline precedence survives manual placement",
            listOf("overdue", "placed", "daily"),
            rank(listOf(candidate("daily", daily = true), candidate("overdue", due = -10 * 86_400.0), candidate("placed", rank = 0))),
        )
    }

    @Test fun handPlacedTasksKeepTheirOwnOrderAmongThemselves() {
        assertEquals(
            listOf("second", "first", "scored", "third"),
            rank(listOf(
                candidate("third", daily = true, rank = 2),
                candidate("first", rank = 0),
                candidate("second", due = -40 * 86_400.0, rank = 1),
                candidate("scored", daily = true),
            )),
        )
    }

    @Test fun clearingOneTasksRankLetsItFallBackToItsScore() {
        assertEquals(listOf("placed", "unplaced"), rank(listOf(candidate("unplaced", daily = true), candidate("placed", rank = 0))))
        assertEquals(listOf("unplaced", "placed"), rank(listOf(candidate("unplaced", daily = true), candidate("placed"))))
    }

    @Test fun rankingIsATotalOrderSoTheLadderNeverShuffles() {
        val candidates = listOf(candidate("a", daily = true), candidate("b", daily = true), candidate("c", due = 0.0), candidate("d"))
        val first = rank(candidates)
        assertEquals("order must not depend on input order", first, rank(candidates.reversed()))
        assertEquals(first.size, first.toSet().size)
    }

    @Test fun aPinIsAPositionNotAPromotion() {
        assertEquals(
            listOf("loose", "pinned", "a", "b"),
            rank(listOf(candidate("loose", daily = true), candidate("pinned", order = 9, rank = 1), candidate("a", order = 0), candidate("b", order = 1))),
        )
    }

    @Test fun pinningOneTaskLeavesEveryOtherTaskRankedByScore() {
        val ranked = rank(listOf(
            candidate("nudged", order = 5, rank = 0), candidate("daily", daily = true),
            candidate("overdue", due = -86_400.0), candidate("idle", order = 3),
        ))
        assertEquals("overdue", ranked.first())
        assertEquals("the unpinned tail keeps its scored order", listOf("nudged", "daily", "idle"), ranked.drop(1))
    }

    @Test fun twoTasksPinnedToTheSameSlotBothSurvive() {
        val ranked = rank(listOf(candidate("first", rank = 0), candidate("second", rank = 0), candidate("free", order = 0)))
        assertEquals(3, ranked.size)
        assertEquals(setOf("first", "second", "free"), ranked.toSet())
        assertEquals(listOf("first", "second"), ranked.take(2))
    }

    @Test fun aPinPastTheEndOfTheLadderTakesTheLastSlotRatherThanVanishing() {
        assertEquals(listOf("a", "b", "far"), rank(listOf(candidate("far", rank = 99), candidate("a", order = 0), candidate("b", order = 1))))
    }

    @Test fun everyTaskPinnedReproducesTheRecordedOrderExactly() {
        assertEquals(
            "a fully pinned ladder ignores score",
            listOf("first", "second", "third"),
            rank(listOf(candidate("third", daily = true, rank = 2), candidate("first", rank = 0), candidate("second", rank = 1))),
        )
    }
}
