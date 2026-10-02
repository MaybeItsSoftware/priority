package uk.co.maybeitsadam.priority.core

import java.time.Instant
import java.time.ZoneId

/** Why a task is part of today. The order of the cases is the order the day is read in. */
enum class DayPlanReason(val raw: String, val label: String) {
    /** The block currently underway. */
    RUNNING("running", "Running"),
    /** Put in the Today column by hand. */
    PLANNED("planned", "Planned"),
    /** Past its deadline. */
    OVERDUE("overdue", "Overdue"),
    /** Its deadline falls today. */
    DUE_TODAY("dueToday", "Due today"),
    /** Its start date is today. */
    STARTS_TODAY("startsToday", "Starts today");

    companion object {
        fun of(raw: String): DayPlanReason? = entries.firstOrNull { it.raw == raw }
    }
}

data class DayPlanEntry(val id: String, val reason: DayPlanReason)

/**
 * Which tasks make up today: the Today column in its hand-made order, then
 * overdue, due today, and starting today, without writing anything back.
 * Port of `DayPlanSelector.swift`.
 */
object DayPlanSelector {
    fun plan(
        candidates: List<NextUpCandidate>,
        todayColumnID: String = NextUpSelector.todayColumnID,
        runningID: String? = null,
        now: Instant,
        zone: ZoneId = ZoneId.systemDefault(),
    ): List<DayPlanEntry> {
        val today = now.atZone(zone).toLocalDate()
        val endOfToday = today.plusDays(1).atStartOfDay(zone).toInstant()
        val entries = mutableListOf<DayPlanEntry>()
        val claimed = mutableSetOf<String>()
        fun claim(candidate: NextUpCandidate, reason: DayPlanReason) {
            if (claimed.add(candidate.id)) entries += DayPlanEntry(candidate.id, reason)
        }

        if (runningID != null) candidates.firstOrNull { it.id == runningID }?.let { claim(it, DayPlanReason.RUNNING) }

        candidates.filter { it.kanbanColumn == todayColumnID }.sortedWith(plannedOrder)
            .forEach { claim(it, DayPlanReason.PLANNED) }

        val dated = candidates.mapNotNull { c -> c.effectiveDeadline(zone)?.let { c to it } }.sortedBy { it.second }
        for ((candidate, deadline) in dated) if (deadline <= now) claim(candidate, DayPlanReason.OVERDUE)
        for ((candidate, deadline) in dated) if (deadline > now && deadline <= endOfToday) claim(candidate, DayPlanReason.DUE_TODAY)

        candidates
            .mapNotNull { c -> c.startAt?.takeIf { it.atZone(zone).toLocalDate() == today }?.let { c to it } }
            .sortedBy { it.second }
            .forEach { claim(it.first, DayPlanReason.STARTS_TODAY) }

        return entries
    }

    /** A hand rank wins; without one, the list's own order, then id. */
    private val plannedOrder = Comparator<NextUpCandidate> { lhs, rhs ->
        val l = lhs.focusRank
        val r = rhs.focusRank
        when {
            l != null && r != null && l != r -> l.compareTo(r)
            l != null && r == null -> -1
            l == null && r != null -> 1
            lhs.sortOrder != rhs.sortOrder -> lhs.sortOrder.compareTo(rhs.sortOrder)
            else -> lhs.id.compareTo(rhs.id)
        }
    }
}
