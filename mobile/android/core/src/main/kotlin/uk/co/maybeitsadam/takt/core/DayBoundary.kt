package uk.co.maybeitsadam.takt.core

import java.time.DayOfWeek
import java.time.Instant
import java.time.ZoneId
import java.time.temporal.TemporalAdjusters

/**
 * Maps an instant onto the *logical* day it belongs to: a day starts at
 * `rolloverHour`, not at midnight. Port of `DayBoundary.swift`.
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

    /** The instant the logical day containing `date` began. Idempotent. */
    fun logicalDay(date: Instant): Instant {
        val shifted = date.atZone(zone).minusHours(rolloverHour.toLong())
        val midnight = shifted.toLocalDate()
        return midnight.atTime(rolloverHour, 0).atZone(zone).toInstant()
    }

    /** `yyyy-MM-dd` for the logical day. */
    fun dayKey(date: Instant): String {
        val day = logicalDay(date).atZone(zone).toLocalDate()
        return "%04d-%02d-%02d".format(day.year, day.monthValue, day.dayOfMonth)
    }

    /** The logical day `offset` days away from the one containing `date`. */
    fun day(offsetBy: Int, from: Instant): Instant =
        logicalDay(from).atZone(zone).plusDays(offsetBy.toLong()).toInstant()

    /** The `count` logical days ending on (and including) the day containing `date`, oldest first. */
    fun days(endingOn: Instant, count: Int): List<Instant> {
        if (count <= 0) return emptyList()
        return (count - 1 downTo 0).map { day(-it, endingOn) }
    }

    /** Start of the calendar week containing the logical day for `date`, rollover-anchored. */
    fun weekStart(date: Instant): Instant {
        val day = logicalDay(date).atZone(zone).toLocalDate()
        val first = DayOfWeek.of(if (firstWeekday == 1) 7 else firstWeekday - 1)
        val midnight = day.with(TemporalAdjusters.previousOrSame(first))
        return midnight.atTime(rolloverHour, 0).atZone(zone).toInstant()
    }

    /** The `count` week starts ending on (and including) the week containing `date`, oldest first. */
    fun weeks(endingOn: Instant, count: Int): List<Instant> {
        if (count <= 0) return emptyList()
        val anchor = weekStart(endingOn).atZone(zone)
        return (count - 1 downTo 0).map { anchor.minusWeeks(it.toLong()).toInstant() }
    }

    override fun equals(other: Any?): Boolean =
        other is DayBoundary && other.rolloverHour == rolloverHour && other.zone == zone && other.firstWeekday == firstWeekday

    override fun hashCode(): Int = (rolloverHour * 31 + zone.hashCode()) * 31 + firstWeekday

    companion object {
        /** 04:00: late enough that a session after midnight lands on the day it belonged to. */
        const val DEFAULT_ROLLOVER_HOUR = 4
    }
}
