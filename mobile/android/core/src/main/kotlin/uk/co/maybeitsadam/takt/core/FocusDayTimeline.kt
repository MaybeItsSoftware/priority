package uk.co.maybeitsadam.takt.core

import java.time.Instant
import java.time.ZoneId
import kotlin.math.roundToInt


/**
 * Placing a day's focus blocks on a clock: a block logged at `endedAt` with
 * `seconds` of work ran from `endedAt - seconds` to `endedAt`. Pure arithmetic;
 * the view supplies points. The arithmetic is the Rust core's.
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

    /**
     * Lays out one day; blocks are clamped to it. The Rust core's
     * `progress::focus_day_layout`, which hands back indices into `blocks`.
     */
    fun layout(blocks: List<Block>, day: Instant, zone: ZoneId = ZoneId.systemDefault()): Layout {
        val layout = uniffi.takt_core.focusDayLayout(
            blocks.map { uniffi.takt_core.TimelineBlock(it.id, it.seconds.toLong(), it.endedAt.coreMillis) },
            day.coreMillis,
            zone.coreName,
        )
        return Layout(
            Instant.ofEpochMilli(layout.startMs),
            Instant.ofEpochMilli(layout.endMs),
            layout.placements.map { Placement(blocks[it.block.toInt()], it.offsetMinutes, it.minutes, it.lane.toInt()) },
            layout.laneCount.toInt(),
        )
    }
}
