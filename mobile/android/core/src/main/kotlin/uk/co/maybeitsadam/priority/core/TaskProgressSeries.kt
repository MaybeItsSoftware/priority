package uk.co.maybeitsadam.priority.core

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
 * included. Port of `TaskProgressSeries.swift`.
 */
data class TaskProgressSeries(val days: List<TaskProgressDay>) {
    val totalCompleted: Int get() = days.sumOf { it.completed }
    val totalAdded: Int get() = days.sumOf { it.added }
    /** Positive when more was closed than added. */
    val net: Int get() = totalCompleted - totalAdded
    val bestDay: TaskProgressDay?
        get() {
            // Swift's `max(by:)` returns the last of equal maxima.
            var best: TaskProgressDay? = null
            for (day in days) if (best == null || best.completed <= day.completed) best = day
            return best?.takeIf { it.completed > 0 }
        }

    companion object {
        /** From the start of the period's first day to the end of today, half open. */
        fun interval(period: TaskProgressPeriod, now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): DateInterval {
            val today = now.atZone(zone).toLocalDate()
            return DateInterval(
                today.minusDays((period.days - 1).toLong()).atStartOfDay(zone).toInstant(),
                today.plusDays(1).atStartOfDay(zone).toInstant(),
            )
        }

        /** Buckets completion and creation times into the period's days; outside times are ignored. */
        fun build(
            period: TaskProgressPeriod,
            completions: List<Instant>,
            creations: List<Instant>,
            now: Instant = Instant.now(),
            zone: ZoneId = ZoneId.systemDefault(),
        ): TaskProgressSeries {
            val interval = interval(period, now, zone)
            fun counts(dates: List<Instant>): Map<Instant, Int> = dates
                .filter { it >= interval.start && it < interval.end }
                .groupingBy { it.atZone(zone).toLocalDate().atStartOfDay(zone).toInstant() }
                .eachCount()
            val done = counts(completions)
            val added = counts(creations)
            var running = 0
            val days = mutableListOf<TaskProgressDay>()
            var day = interval.start.atZone(zone).toLocalDate()
            while (day.atStartOfDay(zone).toInstant() < interval.end) {
                val start = day.atStartOfDay(zone).toInstant()
                val completed = done[start] ?: 0
                running += completed
                days += TaskProgressDay(start, completed, added[start] ?: 0, running)
                day = day.plusDays(1)
            }
            return TaskProgressSeries(days)
        }
    }
}
