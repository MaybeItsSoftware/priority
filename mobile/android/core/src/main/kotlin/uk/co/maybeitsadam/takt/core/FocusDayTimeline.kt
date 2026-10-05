package uk.co.maybeitsadam.takt.core

import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.roundToInt

/**
 * Placing a day's focus blocks on a clock: a block logged at `endedAt` with
 * `seconds` of work ran from `endedAt - seconds` to `endedAt`. Pure arithmetic;
 * the view supplies points. Port of `FocusDayTimeline.swift`.
 */
object FocusDayTimeline {
    class Block(
        val id: String,
        val title: String,
        seconds: Int,
        /** When the block was logged, which is when the work stopped. */
        val endedAt: Instant,
        /** The block currently running. */
        val isLive: Boolean = false,
    ) {
        /** Active seconds credited to the block. Never negative. */
        val seconds: Int = maxOf(0, seconds)

        override fun equals(other: Any?): Boolean = other is Block && other.id == id && other.title == title &&
            other.seconds == seconds && other.endedAt == endedAt && other.isLive == isLive

        override fun hashCode(): Int = id.hashCode()
    }

    data class Placement(
        val block: Block,
        /** Minutes from the start of the window to the start of the block. */
        val offsetMinutes: Double,
        /** The block's own length in minutes, after clamping to the day. */
        val minutes: Double,
        /** Which column this block draws in, counting from the left. */
        val lane: Int,
    ) {
        val id: String get() = block.id
        val startedAt: Instant get() = block.endedAt.minusNanos(Math.round(60 * minutes * 1_000_000_000))
        val endedAt: Instant get() = block.endedAt
    }

    data class Layout(
        val start: Instant,
        val end: Instant,
        val placements: List<Placement>,
        /** At least one. */
        val laneCount: Int,
    ) {
        val hourCount: Int get() = maxOf(1, (secondsBetween(start, end) / 3600).roundToInt())
        /** `hourCount + 1` hour marks, including the closing one. */
        val hours: List<Instant> get() = (0..hourCount).map { start.plusSeconds(it * 3600L) }
    }

    /** The narrowest the ruler gets. */
    const val minimumHours = 5
    /** What a day with nothing in it shows. */
    const val defaultWindowStartHour = 9
    const val defaultWindowEndHour = 18

    /** Lays out one day; blocks are clamped to it. */
    fun layout(blocks: List<Block>, day: Instant, zone: ZoneId = ZoneId.systemDefault()): Layout {
        val dayStartZoned = day.atZone(zone).toLocalDate().atStartOfDay(zone)
        val dayStart = dayStartZoned.toInstant()
        val dayEnd = dayStartZoned.plusDays(1).toInstant()

        data class Span(val block: Block, val start: Instant, val end: Instant)
        val spans = mutableListOf<Span>()
        for (block in blocks) {
            if (block.seconds <= 0) continue
            val end = minOf(maxOf(block.endedAt, dayStart), dayEnd)
            val start = maxOf(end.minusSeconds(block.seconds.toLong()), dayStart)
            if (end <= start) continue
            spans += Span(block, start, end)
        }
        spans.sortWith { a, b -> if (a.start == b.start) a.block.id.compareTo(b.block.id) else a.start.compareTo(b.start) }

        val (windowStart, windowEnd) = window(spans.map { it.start to it.end }, dayStartZoned, dayEnd)

        val laneEnds = mutableListOf<Instant>()
        val placements = mutableListOf<Placement>()
        for (span in spans) {
            var lane = laneEnds.indexOfFirst { it <= span.start }
            if (lane < 0) lane = laneEnds.size
            if (lane == laneEnds.size) laneEnds += span.end else laneEnds[lane] = span.end
            placements += Placement(
                block = span.block,
                offsetMinutes = secondsBetween(windowStart, span.start) / 60,
                minutes = secondsBetween(span.start, span.end) / 60,
                lane = lane,
            )
        }
        return Layout(windowStart, windowEnd, placements, maxOf(1, laneEnds.size))
    }

    private fun window(
        spans: List<Pair<Instant, Instant>>,
        dayStart: java.time.ZonedDateTime,
        dayEnd: Instant,
    ): Pair<Instant, Instant> {
        val earliest = spans.minOfOrNull { it.first }
        val latest = spans.maxOfOrNull { it.second }
        if (earliest == null || latest == null) {
            return dayStart.plusHours(defaultWindowStartHour.toLong()).toInstant() to
                dayStart.plusHours(defaultWindowEndHour.toLong()).toInstant()
        }
        val startOfDay = dayStart.toInstant()
        var start = startOfDay.plusSeconds(maxOf(0.0, floor(secondsBetween(startOfDay, earliest) / 3600)).toLong() * 3600)
        var end = startOfDay.plusSeconds(maxOf(1.0, ceil(secondsBetween(startOfDay, latest) / 3600)).toLong() * 3600)
        val minimum = Duration.ofHours(minimumHours.toLong())
        if (Duration.between(start, end) < minimum) {
            end = start.plus(minimum)
            if (end > dayEnd) {
                end = dayEnd
                start = maxOf(startOfDay, end.minus(minimum))
            }
        }
        return start to end
    }
}
