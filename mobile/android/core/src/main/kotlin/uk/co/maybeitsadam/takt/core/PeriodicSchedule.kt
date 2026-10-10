package uk.co.maybeitsadam.takt.core

import java.time.Instant
import java.time.ZoneId

/**
 * How often a task comes round, as `PeriodicSchedule.swift` has it.
 *
 * The vocabulary is the one stored in `task_metadata.recurrenceRule`: `daily`,
 * `weekdays`, `weekly`, `every 3 days`, `every 2 weeks`, `every monday`. The
 * parsing and the stepping are the Rust core's (`core/src/periodic.rs`); this
 * keeps the type and the words a screen shows.
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
     * on the wall clock in [zone] until it lands past the threshold. Null only
     * for a cadence that cannot land.
     */
    fun nextOccurrence(
        after: Instant,
        notBefore: Instant? = null,
        zone: ZoneId = ZoneId.systemDefault(),
    ): Instant? = uniffi.takt_core.periodicNextOccurrence(cadence.core, after.coreMillis, notBefore?.coreMillis, zone.coreName)
        ?.let(Instant::ofEpochMilli)

    companion object {
        /** Swift's failable `init?(_ raw:)`. */
        fun parse(raw: String): PeriodicSchedule? {
            val cadence = uniffi.takt_core.periodicCadence(raw) ?: return null
            return PeriodicSchedule(raw.trim().lowercase(), cadence.cadence)
        }

        /** A weekday's name or abbreviation (`monday`, `thu`) as a calendar weekday number, 1 = Sunday. */
        fun weekdayNumber(name: String): Int? =
            (uniffi.takt_core.periodicCadence("every $name")?.cadence as? Cadence.Weekday)?.weekday

        fun weekdayName(weekday: Int): String {
            val names = listOf("Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday")
            return if (weekday in 1..7) names[weekday - 1] else "Day $weekday"
        }
    }
}

private val uniffi.takt_core.PeriodicCadence.cadence: PeriodicSchedule.Cadence
    get() = when (this) {
        is uniffi.takt_core.PeriodicCadence.Days -> PeriodicSchedule.Cadence.Days(count.toInt())
        is uniffi.takt_core.PeriodicCadence.Weeks -> PeriodicSchedule.Cadence.Weeks(count.toInt())
        is uniffi.takt_core.PeriodicCadence.Weekdays -> PeriodicSchedule.Cadence.Weekdays
        is uniffi.takt_core.PeriodicCadence.Weekday -> PeriodicSchedule.Cadence.Weekday(weekday.toInt())
    }

private fun Int.unsigned(): UInt = coerceAtLeast(0).toUInt()

private val PeriodicSchedule.Cadence.core: uniffi.takt_core.PeriodicCadence
    get() = when (this) {
        is PeriodicSchedule.Cadence.Days -> uniffi.takt_core.PeriodicCadence.Days(count.unsigned())
        is PeriodicSchedule.Cadence.Weeks -> uniffi.takt_core.PeriodicCadence.Weeks(count.unsigned())
        PeriodicSchedule.Cadence.Weekdays -> uniffi.takt_core.PeriodicCadence.Weekdays
        is PeriodicSchedule.Cadence.Weekday -> uniffi.takt_core.PeriodicCadence.Weekday(weekday.unsigned())
    }
