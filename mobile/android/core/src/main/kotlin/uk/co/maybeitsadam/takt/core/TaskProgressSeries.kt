package uk.co.maybeitsadam.takt.core

import java.time.Instant
import java.time.ZoneId

/** How far back the progress graph looks. */
enum class TaskProgressPeriod(val raw: String, val days: Int, val shortTitle: String) {
    WEEK("week", 7, "7D"),
    MONTH("month", 30, "30D"),
    QUARTER("quarter", 90, "90D");

    companion object {
        fun of(raw: String): TaskProgressPeriod? = entries.firstOrNull { it.raw == raw }
    }
}

/** One day on the progress graph. */
data class TaskProgressDay(
    val dayStart: Instant,
    /** Tasks closed that day. */
    val completed: Int,
    /** Tasks added that day. */
    val added: Int,
    /** Tasks closed from the first day of the period to the end of this one. */
    val cumulativeCompleted: Int,
) {
    val id: Instant get() = dayStart
}

/** A half-open interval, Swift's `DateInterval`. */
data class DateInterval(val start: Instant, val end: Instant)

/**
 * Task progress over a period, a day at a time. Every day is present, empty ones
 * included. The bucketing is the Rust core's `progress::task_progress_days`.
 */
data class TaskProgressSeries(val days: List<TaskProgressDay>) {
    val totalCompleted: Int get() = days.sumOf { it.completed }
    val totalAdded: Int get() = days.sumOf { it.added }
    /** Positive when more was closed than added. */
    val net: Int get() = totalCompleted - totalAdded
    val bestDay: TaskProgressDay?
        get() {
            // Swift's `max(by:)` returns the first of equal maxima.
            var best: TaskProgressDay? = null
            for (day in days) if (best == null || best.completed < day.completed) best = day
            return best?.takeIf { it.completed > 0 }
        }

    companion object {
        /** From the start of the period's first day to the end of today, half open. */
        fun interval(period: TaskProgressPeriod, now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): DateInterval {
            val span = uniffi.takt_core.taskProgressInterval(period.days.toUInt(), now.coreMillis, zone.coreName)
            return DateInterval(Instant.ofEpochMilli(span.startMs), Instant.ofEpochMilli(span.endMs))
        }

        /** Buckets completion and creation times into the period's days; outside times are ignored. */
        fun build(
            period: TaskProgressPeriod,
            completions: List<Instant>,
            creations: List<Instant>,
            now: Instant = Instant.now(),
            zone: ZoneId = ZoneId.systemDefault(),
        ): TaskProgressSeries = TaskProgressSeries(
            uniffi.takt_core.taskProgressDays(
                period.days.toUInt(),
                completions.map { it.coreMillis },
                creations.map { it.coreMillis },
                now.coreMillis,
                zone.coreName,
            ).map {
                TaskProgressDay(
                    Instant.ofEpochMilli(it.dayStartMs),
                    it.completed.toInt(),
                    it.added.toInt(),
                    it.cumulativeCompleted.toInt(),
                )
            },
        )
    }
}

/**
 * Review's progress charts, a day at a time: completions, creations and focus
 * minutes bucketed into local days by the Rust core's `review` module.
 */
data class ReviewProgressDays(
    val days: List<Day>,
    val totalCompleted: Int,
    val totalAdded: Int,
    val focusMinutes: Int,
    /** Index into [days]: the first of the days that closed the most, when any closed one. */
    val bestDay: Int?,
) {
    data class Day(
        val dayStart: Instant,
        val completed: Int,
        val added: Int,
        /** Whole minutes of focus logged that day. */
        val focusMinutes: Int,
        val cumulativeCompleted: Int,
        val cumulativeAdded: Int,
    )

    companion object {
        fun of(core: uniffi.takt_core.ReviewProgress) = ReviewProgressDays(
            days = core.days.map {
                Day(
                    Instant.ofEpochMilli(it.dayStartMs), it.completed.toInt(), it.added.toInt(), it.focusMinutes.toInt(),
                    it.cumulativeCompleted.toInt(), it.cumulativeAdded.toInt(),
                )
            },
            totalCompleted = core.totalCompleted.toInt(),
            totalAdded = core.totalAdded.toInt(),
            focusMinutes = core.focusMinutes.toInt(),
            bestDay = core.bestDay?.toInt(),
        )

        /** The same from moments in hand: `review::summarise_review_progress`. */
        fun summarise(
            period: TaskProgressPeriod,
            completions: List<Instant>,
            creations: List<Instant>,
            blocks: List<Pair<Int, Instant>>,
            now: Instant,
            zone: ZoneId = ZoneId.systemDefault(),
        ): ReviewProgressDays = of(
            uniffi.takt_core.summariseReviewProgress(
                period.days.toUInt(),
                completions.map { it.coreMillis },
                creations.map { it.coreMillis },
                blocks.map { (seconds, at) -> uniffi.takt_core.WorkBlockSeconds(seconds.toLong(), at.coreMillis) },
                now.coreMillis,
                zone.coreName,
            ),
        )
    }
}
