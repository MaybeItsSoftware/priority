package uk.co.maybeitsadam.takt.core

import java.time.Instant
import java.time.ZoneId

/**
 * How often a task comes round. Port of `PeriodicSchedule.swift`.
 *
 * The vocabulary is the one stored in `task_metadata.recurrenceRule`: `daily`,
 * `weekdays`, `weekly`, `every 3 days`, `every 2 weeks`, `every monday`.
 */
data class PeriodicSchedule(
    /** The phrase as it was stored, normalised to lowercase. */
    val raw: String,
    val cadence: Cadence,
) {
    sealed interface Cadence {
        data class Days(val count: Int) : Cadence
        data class Weeks(val count: Int) : Cadence
        /** Monday to Friday, skipping the weekend. */
        data object Weekdays : Cadence
        /** A Calendar weekday number, 1 = Sunday through 7 = Saturday. */
        data class Weekday(val weekday: Int) : Cadence
    }

    val displayLabel: String
        get() = when (val c = cadence) {
            is Cadence.Days -> if (c.count == 1) "Daily" else "Every ${c.count} days"
            is Cadence.Weeks -> if (c.count == 1) "Weekly" else "Every ${c.count} weeks"
            Cadence.Weekdays -> "Weekdays"
            is Cadence.Weekday -> "Every ${weekdayName(c.weekday)}"
        }

    /**
     * The first occurrence strictly after `reference`, and also strictly after
     * `notBefore` when one is given; the cadence is stepped (keeping its rhythm)
     * until it lands past the threshold. Null only past 400 steps.
     */
    fun nextOccurrence(
        after: Instant,
        notBefore: Instant? = null,
        zone: ZoneId = ZoneId.systemDefault(),
    ): Instant? {
        val threshold = maxOf(after, notBefore ?: after)
        var candidate = after
        repeat(400) {
            candidate = step(candidate, zone)
            if (candidate > threshold) return candidate
        }
        return null
    }

    private fun step(date: Instant, zone: ZoneId): Instant {
        val zoned = date.atZone(zone)
        return when (val c = cadence) {
            is Cadence.Days -> zoned.plusDays(c.count.toLong()).toInstant()
            is Cadence.Weeks -> zoned.plusWeeks(c.count.toLong()).toInstant()
            Cadence.Weekdays -> {
                var next = zoned.plusDays(1)
                while (calendarWeekday(next.toLocalDate()) == 1 || calendarWeekday(next.toLocalDate()) == 7) {
                    next = next.plusDays(1)
                }
                next.toInstant()
            }
            is Cadence.Weekday -> {
                var next = zoned.plusDays(1)
                for (i in 0 until 7) {
                    if (calendarWeekday(next.toLocalDate()) == c.weekday) return next.toInstant()
                    next = next.plusDays(1)
                }
                next.toInstant()
            }
        }
    }

    companion object {
        private val everyN = Regex("""^every\s+(\d+)\s+(day|days|week|weeks|wk|wks)$""")

        /** Swift's failable `init?(_ raw:)`. */
        fun parse(raw: String): PeriodicSchedule? {
            val normalized = raw.trim().lowercase()
            val cadence = parseCadence(normalized) ?: return null
            return PeriodicSchedule(normalized, cadence)
        }

        private fun parseCadence(text: String): Cadence? {
            when (text) {
                "" -> return null
                "daily", "every day" -> return Cadence.Days(1)
                "weekly", "every week" -> return Cadence.Weeks(1)
                "weekdays", "every weekday" -> return Cadence.Weekdays
            }
            everyN.find(text)?.let { match ->
                val count = match.groupValues[1].toIntOrNull() ?: return null
                if (count <= 0) return null
                val unit = match.groupValues[2]
                return if (unit.startsWith("week") || unit.startsWith("wk")) Cadence.Weeks(count) else Cadence.Days(count)
            }
            val name = if (text.startsWith("every ")) text.removePrefix("every ") else text
            return weekdayNumber(name)?.let { Cadence.Weekday(it) }
        }

        fun weekdayNumber(name: String): Int? = when (name) {
            "sunday", "sun" -> 1
            "monday", "mon" -> 2
            "tuesday", "tue", "tues" -> 3
            "wednesday", "wed" -> 4
            "thursday", "thu", "thur", "thurs" -> 5
            "friday", "fri" -> 6
            "saturday", "sat" -> 7
            else -> null
        }

        fun weekdayName(weekday: Int): String {
            val names = listOf("Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday")
            return if (weekday in 1..7) names[weekday - 1] else "Day $weekday"
        }
    }
}
