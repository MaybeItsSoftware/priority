package uk.co.maybeitsadam.takt.core

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
 * Which tasks make up today: the running block, the Today column in its
 * hand-made order, then overdue, due today, and starting today, without
 * writing anything back. The Rust core's `next_up::plan`, which the data
 * layer's next-up snapshot runs without the candidates leaving the core.
 */
object DayPlanSelector {
    fun plan(
        candidates: List<NextUpCandidate>,
        runningID: String? = null,
        now: Instant,
        zone: ZoneId = ZoneId.systemDefault(),
    ): List<DayPlanEntry> = uniffi.takt_core.planDay(candidates.map { it.core }, runningID, now.coreMillis, zone.coreName)
        .map { DayPlanEntry(it.id, DayPlanReason.of(it.reason) ?: DayPlanReason.PLANNED) }
}
