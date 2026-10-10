package uk.co.maybeitsadam.takt.core

import java.time.Instant
import java.time.ZoneId

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

/**
 * Buckets finished work into days, newest first. The Rust core's
 * `progress::group_completed_work`, which hands back indices so only the
 * moments cross.
 */
object CompletedWorkDigest {
    /** Groups by the calendar day of `completedAt`, days newest first, each day's items newest first. */
    fun <Item> group(
        items: List<Item>,
        completedAt: (Item) -> Instant,
        now: Instant = Instant.now(),
        zone: ZoneId = ZoneId.systemDefault(),
    ): List<CompletedWorkGroup<Item>> =
        uniffi.takt_core.groupCompletedWork(items.map { completedAt(it).coreMillis }, now.coreMillis, zone.coreName)
            .map { day ->
                CompletedWorkGroup(
                    Instant.ofEpochMilli(day.dayStartMs),
                    day.kind.digestKind,
                    day.items.map { items[it.toInt()] },
                )
            }

    /** How far back `day` is from the day containing `now`, counted in calendar days. */
    fun kind(day: Instant, now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): CompletedWorkDayKind =
        uniffi.takt_core.completedDayKind(day.coreMillis, now.coreMillis, zone.coreName).digestKind
}

private val uniffi.takt_core.CompletedDayKind.digestKind: CompletedWorkDayKind
    get() = when (this) {
        uniffi.takt_core.CompletedDayKind.TODAY -> CompletedWorkDayKind.TODAY
        uniffi.takt_core.CompletedDayKind.YESTERDAY -> CompletedWorkDayKind.YESTERDAY
        uniffi.takt_core.CompletedDayKind.THIS_WEEK -> CompletedWorkDayKind.THIS_WEEK
        uniffi.takt_core.CompletedDayKind.EARLIER -> CompletedWorkDayKind.EARLIER
    }
