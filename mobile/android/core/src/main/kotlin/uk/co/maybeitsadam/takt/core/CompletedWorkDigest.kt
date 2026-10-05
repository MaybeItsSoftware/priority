package uk.co.maybeitsadam.takt.core

import java.time.Instant
import java.time.ZoneId
import java.time.temporal.ChronoUnit

/** Which day a finished thing belongs to, as a relation rather than a string. */
enum class CompletedWorkDayKind {
    TODAY,
    YESTERDAY,
    /** Within the last week, so a weekday name still identifies it. */
    THIS_WEEK,
    /** Long enough ago that it needs a date. */
    EARLIER,
}

/** One day's worth of finished work. */
data class CompletedWorkGroup<Item>(val dayStart: Instant, val kind: CompletedWorkDayKind, val items: List<Item>) {
    val id: Instant get() = dayStart
}

/** Buckets finished work into days, newest first. Port of `CompletedWorkDigest.swift`. */
object CompletedWorkDigest {
    /** Groups by the calendar day of `completedAt`, days newest first, each day's items newest first. */
    fun <Item> group(
        items: List<Item>,
        completedAt: (Item) -> Instant,
        now: Instant = Instant.now(),
        zone: ZoneId = ZoneId.systemDefault(),
    ): List<CompletedWorkGroup<Item>> {
        val buckets = items.groupBy { completedAt(it).atZone(zone).toLocalDate().atStartOfDay(zone).toInstant() }
        return buckets.keys.sortedDescending().map { dayStart ->
            CompletedWorkGroup(
                dayStart,
                kind(dayStart, now, zone),
                buckets.getValue(dayStart).sortedByDescending(completedAt),
            )
        }
    }

    /** How far back `day` is from the day containing `now`, counted in calendar days. */
    fun kind(day: Instant, now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): CompletedWorkDayKind {
        val days = ChronoUnit.DAYS.between(day.atZone(zone).toLocalDate(), now.atZone(zone).toLocalDate())
        return when {
            days < 1 -> CompletedWorkDayKind.TODAY
            days == 1L -> CompletedWorkDayKind.YESTERDAY
            days in 2..6 -> CompletedWorkDayKind.THIS_WEEK
            else -> CompletedWorkDayKind.EARLIER
        }
    }
}
