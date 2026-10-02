package uk.co.maybeitsadam.priority.core

import java.time.Instant
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import java.util.UUID

/**
 * A recurring intention on a schedule: fixed weekdays, or every N days from an
 * anchor (the interval wins when set). Carries no completion state. Port of
 * `Daily.swift` (the plugin-era model; the workspace's own is `WorkspaceDaily`).
 */
class Daily(
    val id: String = UUID.randomUUID().toString().uppercase(),
    var title: String,
    activeWeekdays: Set<Int> = ALL_WEEKDAYS,
    intervalDays: Int? = null,
    var intervalAnchor: Instant? = null,
    var sortIndex: Int = 0,
    var createdAt: Instant = Instant.now(),
    var archivedAt: Instant? = null,
) {
    /** Calendar numbering (1 = Sunday). Ignored while `intervalDays` is set, but kept. */
    var activeWeekdays: Set<Int> = activeWeekdays.ifEmpty { ALL_WEEKDAYS }
    var intervalDays: Int? = intervalDays?.let { clampInterval(it) }

    val isArchived: Boolean get() = archivedAt != null

    val isEveryDay: Boolean
        get() = intervalDays?.let { it <= 1 } ?: (activeWeekdays == ALL_WEEKDAYS)

    /** Whether this is expected on the logical day beginning at `day`. */
    fun isDue(day: Instant, zone: ZoneId = ZoneId.systemDefault()): Boolean {
        if (isArchived) return false
        val interval = intervalDays
        if (interval != null) {
            if (interval <= 1) return true
            val anchor = (intervalAnchor ?: createdAt).atZone(zone).toLocalDate()
            val target = day.atZone(zone).toLocalDate()
            val delta = ChronoUnit.DAYS.between(anchor, target)
            // Non-negative modulo, so the cycle also extends backwards from the anchor.
            return ((delta % interval) + interval) % interval == 0L
        }
        return calendarWeekday(day.atZone(zone).toLocalDate()) in activeWeekdays
    }

    val scheduleLabel: String get() = scheduleLabel(schedule)

    /** The two ways a daily can recur, as one value. */
    sealed interface Schedule {
        data class Weekdays(val days: Set<Int>) : Schedule
        data class EveryNDays(val days: Int) : Schedule
    }

    val schedule: Schedule
        get() = intervalDays?.let { Schedule.EveryNDays(it) } ?: Schedule.Weekdays(activeWeekdays)

    /** Applies a schedule; an existing anchor is kept when only the length changes. */
    fun setSchedule(schedule: Schedule, anchor: Instant = Instant.now()) {
        when (schedule) {
            is Schedule.Weekdays -> {
                activeWeekdays = schedule.days.ifEmpty { ALL_WEEKDAYS }
                intervalDays = null
                intervalAnchor = null
            }
            is Schedule.EveryNDays -> {
                intervalDays = clampInterval(schedule.days)
                intervalAnchor = intervalAnchor ?: anchor
            }
        }
    }

    fun copy(): Daily = Daily(id, title, activeWeekdays, intervalDays, intervalAnchor, sortIndex, createdAt, archivedAt)

    override fun equals(other: Any?): Boolean = other is Daily && other.id == id && other.title == title &&
        other.activeWeekdays == activeWeekdays && other.intervalDays == intervalDays &&
        other.intervalAnchor == intervalAnchor && other.sortIndex == sortIndex &&
        other.createdAt == createdAt && other.archivedAt == archivedAt

    override fun hashCode(): Int = id.hashCode()

    companion object {
        val ALL_WEEKDAYS: Set<Int> = setOf(1, 2, 3, 4, 5, 6, 7)
        val MONDAY_TO_FRIDAY: Set<Int> = setOf(2, 3, 4, 5, 6)
        val WEEKEND: Set<Int> = setOf(1, 7)
        val INTERVAL_RANGE = 1..366

        fun clampInterval(days: Int): Int = days.coerceIn(INTERVAL_RANGE)

        fun scheduleLabel(schedule: Schedule): String = when (schedule) {
            is Schedule.EveryNDays -> when {
                schedule.days <= 1 -> "Every day"
                schedule.days == 2 -> "Every other day"
                else -> "Every ${schedule.days} days"
            }
            is Schedule.Weekdays -> when (schedule.days) {
                ALL_WEEKDAYS -> "Every day"
                MONDAY_TO_FRIDAY -> "Weekdays"
                WEEKEND -> "Weekends"
                else -> {
                    val names = listOf("", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat")
                    schedule.days.sorted().filter { it in ALL_WEEKDAYS }.joinToString(" ") { names[it] }
                }
            }
        }
    }
}

/** The whole set of dailies, as persisted. Port of `DailyCollection`. */
class DailyCollection(dailies: List<Daily> = emptyList()) {
    val version: Int = 1
    val dailies: MutableList<Daily> = dailies.toMutableList()

    private val displayOrder = compareBy<Daily>({ it.sortIndex }, { it.createdAt })

    /** Active dailies in display order, filtered to those expected on `day`. */
    fun due(day: Instant, zone: ZoneId = ZoneId.systemDefault()): List<Daily> =
        dailies.filter { it.isDue(day, zone) }.sortedWith(displayOrder)

    /** Every non-archived daily in display order. */
    val active: List<Daily> get() = dailies.filter { !it.isArchived }.sortedWith(displayOrder)

    fun daily(id: String): Daily? = dailies.firstOrNull { it.id == id }

    /** Appends at the end of the current order. */
    fun add(daily: Daily) {
        val copy = daily.copy()
        copy.sortIndex = (dailies.maxOfOrNull { it.sortIndex } ?: -1) + 1
        dailies += copy
    }

    fun update(id: String, transform: (Daily) -> Unit) {
        dailies.firstOrNull { it.id == id }?.let(transform)
    }

    fun archive(id: String, at: Instant = Instant.now()) = update(id) { it.archivedAt = at }

    fun restore(id: String) = update(id) { it.archivedAt = null }

    /** Moves a daily by `offset` places within the active order, renumbering densely. */
    fun move(id: String, by: Int) {
        val ordered = active.toMutableList()
        val from = ordered.indexOfFirst { it.id == id }
        if (from < 0) return
        val to = (from + by).coerceIn(0, ordered.size - 1)
        if (to == from) return
        val moved = ordered.removeAt(from)
        ordered.add(to, moved)
        ordered.forEachIndexed { index, daily -> update(daily.id) { it.sortIndex = index } }
    }
}
