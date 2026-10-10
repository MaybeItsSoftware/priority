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

    /** One task's share of the day: its key (task id, else title), its latest title, time and blocks. */
    data class TaskSummary(val id: String, val title: String, val seconds: Int, val blocks: Int)

    /** A day of focus as Review's timeline draws it. A summary's place is its hue. */
    data class ReviewDay(
        val layout: Layout,
        /** Most time first, ties by key. */
        val summaries: List<TaskSummary>,
        /** Block id to task key, for the blocks kept. */
        val taskKeys: Map<String, String>,
        val totalSeconds: Int,
        val points: Double,
    )

    /**
     * Shapes one day of Review's timeline: [blocks] are the day's logged blocks
     * then the running one, if any, marked `isLive` and ending now; [taskKeys]
     * names each block's task. A block with no time is left out, and so is the
     * running block on any day but today's. Points are the awards (which share
     * their block's id) of the logged blocks kept. The Rust core's
     * `review::review_timeline`, which hands back indices into [blocks].
     */
    fun reviewDay(
        blocks: List<Block>,
        taskKeys: List<String>,
        awards: List<Pair<String, Double>>,
        day: Instant,
        now: Instant,
        zone: ZoneId = ZoneId.systemDefault(),
    ): ReviewDay {
        val shaped = uniffi.takt_core.reviewTimeline(
            blocks.mapIndexed { index, block ->
                uniffi.takt_core.ReviewTimelineBlock(
                    block.id, taskKeys[index], block.seconds.toLong(), block.endedAt.coreMillis, block.isLive,
                )
            },
            awards.map { (id, points) -> uniffi.takt_core.ReviewAwardPoints(id, points) },
            day.coreMillis,
            now.coreMillis,
            zone.coreName,
        )
        val layout = shaped.layout
        return ReviewDay(
            layout = Layout(
                Instant.ofEpochMilli(layout.startMs),
                Instant.ofEpochMilli(layout.endMs),
                layout.placements.map { Placement(blocks[it.block.toInt()], it.offsetMinutes, it.minutes, it.lane.toInt()) },
                layout.laneCount.toInt(),
            ),
            summaries = shaped.summaries.map {
                TaskSummary(it.key, blocks[it.latest.toInt()].title, it.seconds.toInt(), it.blocks.toInt())
            },
            taskKeys = shaped.kept.associate { blocks[it.toInt()].id to taskKeys[it.toInt()] },
            totalSeconds = shaped.totalSeconds.toInt(),
            points = shaped.points,
        )
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
