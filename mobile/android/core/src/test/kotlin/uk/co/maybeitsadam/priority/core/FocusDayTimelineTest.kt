package uk.co.maybeitsadam.priority.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

class FocusDayTimelineTest {
    private val day = epoch(1_700_000_000)

    private fun at(hour: Int, minute: Int = 0): Instant =
        day.atZone(UTC).toLocalDate().atTime(hour, minute).atZone(UTC).toInstant()

    private fun block(id: String, endedAt: Instant, minutes: Int, isLive: Boolean = false) =
        FocusDayTimeline.Block(id, id, minutes * 60, endedAt, isLive)

    private fun layout(vararg blocks: FocusDayTimeline.Block) = FocusDayTimeline.layout(blocks.toList(), day, UTC)

    @Test fun itPlacesABlockWhereItRanRatherThanWhereItWasLogged() {
        val l = layout(block("a", at(10, 30), 30))
        val placement = l.placements.first()
        assertEquals(30.0, placement.minutes, 0.0)
        assertEquals(at(10, 0), placement.startedAt)
        assertEquals(at(10, 0), l.start)
    }

    @Test fun theWindowCoversEveryBlockOnWholeHours() {
        val l = layout(block("morning", at(9, 20), 35), block("evening", at(17, 10), 40))
        assertEquals(at(8, 0), l.start)
        assertEquals(at(18, 0), l.end)
        assertEquals(10, l.hourCount)
        assertEquals(11, l.hours.size)
        assertEquals(45.0, l.placements.first().offsetMinutes, 0.0)
    }

    @Test fun aShortDayStillGetsAReadableRuler() {
        val l = layout(block("a", at(14, 20), 20))
        assertEquals(FocusDayTimeline.minimumHours, l.hourCount)
        assertEquals(at(14, 0), l.start)
    }

    @Test fun aMinimumWindowNeverOverhangsTheEndOfTheDay() {
        val l = layout(block("late", at(23, 50), 20))
        assertEquals(startOfDay(day).plusSeconds(86_400), l.end)
        assertEquals(FocusDayTimeline.minimumHours, l.hourCount)
    }

    @Test fun anEmptyDayKeepsItsShape() {
        val l = layout()
        assertTrue(l.placements.isEmpty())
        assertEquals(1, l.laneCount)
        assertEquals(at(9, 0), l.start)
        assertEquals(at(18, 0), l.end)
    }

    @Test fun overlappingBlocksTakeSeparateLanes() {
        val l = layout(block("a", at(11, 0), 60), block("b", at(11, 30), 60), block("c", at(13, 0), 30))
        assertEquals(2, l.laneCount)
        assertEquals(listOf(0, 1, 0), l.placements.map { it.lane })
    }

    @Test fun workRunningThroughMidnightIsClampedToTheDayItLandsOn() {
        val l = layout(block("overnight", at(0, 30), 90))
        assertEquals(30.0, l.placements.first().minutes, 0.0)
        assertEquals(startOfDay(day), l.placements.first().startedAt)
        assertEquals(startOfDay(day), l.start)
    }

    @Test fun blocksWithNoTimeInThemAreNotDrawn() {
        assertTrue(layout(block("empty", at(12, 0), 0)).placements.isEmpty())
    }

    @Test fun theLiveBlockIsPlacedLikeAnyOther() {
        val l = layout(block("logged", at(10, 0), 25), block("running", at(11, 15), 15, isLive = true))
        assertEquals(true, l.placements.last().block.isLive)
        assertEquals(120.0, l.placements.last().offsetMinutes, 0.0)
    }
}
