package uk.co.maybeitsadam.takt.core

import java.time.Instant
import java.time.ZoneId
import uniffi.takt_core.DayLogBoundary
import uniffi.takt_core.dayBoundaryDayKey
import uniffi.takt_core.dayBoundaryDayOffset
import uniffi.takt_core.dayBoundaryDaysEndingOn
import uniffi.takt_core.dayBoundaryLogicalDay
import uniffi.takt_core.dayBoundaryWeekStart
import uniffi.takt_core.dayBoundaryWeeksEndingOn

/**
 * Maps an instant onto the *logical* day it belongs to: a day starts at
 * `rolloverHour`, not at midnight. The arithmetic is the Rust core's
 * (`core/src/day_log.rs`), which `DayBoundary.swift` wraps too.
 *
 * `firstWeekday` stands in for `Calendar.firstWeekday` (1 = Sunday, 2 = Monday),
 * defaulting to the locale's as `Calendar.current` does.
 */
class DayBoundary(
    rolloverHour: Int = DEFAULT_ROLLOVER_HOUR,
    val zone: ZoneId = ZoneId.systemDefault(),
    val firstWeekday: Int = defaultFirstWeekday(),
) {
    val rolloverHour: Int = rolloverHour.coerceIn(0, 23)

    private val core = DayLogBoundary(this.rolloverHour, zone.coreName, firstWeekday.coerceIn(1, 7).toUByte())

    /** The instant the logical day containing `date` began. Idempotent. */
    fun logicalDay(date: Instant): Instant = Instant.ofEpochMilli(dayBoundaryLogicalDay(core, date.coreMillis))

    /** `yyyy-MM-dd` for the logical day. */
    fun dayKey(date: Instant): String = dayBoundaryDayKey(core, date.coreMillis)

    /** The logical day `offset` days away from the one containing `date`. */
    fun day(offsetBy: Int, from: Instant): Instant =
        Instant.ofEpochMilli(dayBoundaryDayOffset(core, offsetBy.toLong(), from.coreMillis))

    /** The `count` logical days ending on (and including) the day containing `date`, oldest first. */
    fun days(endingOn: Instant, count: Int): List<Instant> =
        dayBoundaryDaysEndingOn(core, endingOn.coreMillis, count.toLong()).map(Instant::ofEpochMilli)

    /** Start of the calendar week containing the logical day for `date`, rollover-anchored. */
    fun weekStart(date: Instant): Instant = Instant.ofEpochMilli(dayBoundaryWeekStart(core, date.coreMillis))

    /** The `count` week starts ending on (and including) the week containing `date`, oldest first. */
    fun weeks(endingOn: Instant, count: Int): List<Instant> =
        dayBoundaryWeeksEndingOn(core, endingOn.coreMillis, count.toLong()).map(Instant::ofEpochMilli)

    override fun equals(other: Any?): Boolean =
        other is DayBoundary && other.rolloverHour == rolloverHour && other.zone == zone && other.firstWeekday == firstWeekday

    override fun hashCode(): Int = (rolloverHour * 31 + zone.hashCode()) * 31 + firstWeekday

    companion object {
        /** 04:00: late enough that a session after midnight lands on the day it belonged to. */
        const val DEFAULT_ROLLOVER_HOUR = 4
    }
}
