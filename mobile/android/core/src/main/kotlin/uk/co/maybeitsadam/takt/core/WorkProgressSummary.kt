package uk.co.maybeitsadam.takt.core

import java.time.Instant
import java.time.ZoneId

/** One day's or one week's worth of finished work. */
data class WorkTotals(
    /** Tasks closed in the period. */
    val completed: Int,
    /** Seconds recorded against focus blocks in the period. */
    val seconds: Int,
) {
    companion object {
        val ZERO = WorkTotals(0, 0)
    }
}

/** Today set against the week it belongs to. */
class WorkProgress(
    val today: WorkTotals,
    val week: WorkTotals,
    elapsedDays: Int,
) {
    /** Days of the week that have already happened, today included. At least one. */
    val elapsedDays: Int = maxOf(1, elapsedDays)

    val averageSecondsPerDay: Int get() = week.seconds / elapsedDays

    /** Today's time as a fraction of the week's average; 1.0 is an ordinary day. */
    val paceAgainstWeek: Double
        get() {
            val average = averageSecondsPerDay
            if (average <= 0) return if (today.seconds > 0) 1.0 else 0.0
            return today.seconds.toDouble() / average
        }

    /** Today's share of everything logged this week, 0...1. */
    val shareOfWeek: Double
        get() = if (week.seconds <= 0) 0.0 else minOf(1.0, today.seconds.toDouble() / week.seconds)

    override fun equals(other: Any?): Boolean =
        other is WorkProgress && other.today == today && other.week == week && other.elapsedDays == elapsedDays

    override fun hashCode(): Int = (today.hashCode() * 31 + week.hashCode()) * 31 + elapsedDays

    override fun toString(): String = "WorkProgress(today=$today, week=$week, elapsedDays=$elapsedDays)"

    companion object {
        val EMPTY = WorkProgress(WorkTotals.ZERO, WorkTotals.ZERO, 1)
    }
}

/** A focus block as `WorkProgressSummary` needs it: `(seconds, recordedAt)`. */
data class WorkBlockTime(val seconds: Int, val recordedAt: Instant)

/**
 * Builds `WorkProgress` from raw timestamps: the Rust core's
 * `progress::summarise_work_progress`. The repository asks the core's
 * `workProgress` instead, which reads the rows without them crossing.
 */
object WorkProgressSummary {
    fun summarise(
        completions: List<Instant>,
        blocks: List<WorkBlockTime>,
        now: Instant,
        zone: ZoneId = ZoneId.systemDefault(),
        firstWeekday: Int = defaultFirstWeekday(),
    ): WorkProgress = WorkProgress.of(
        uniffi.takt_core.summariseWorkProgress(
            completions.map { it.coreMillis },
            blocks.map { uniffi.takt_core.WorkBlockSeconds(it.seconds.toLong(), it.recordedAt.coreMillis) },
            now.coreMillis,
            zone.coreName,
            firstWeekday.toUByte(),
        ),
    )

    /** The user's own week: `firstWeekday` is Calendar numbering (1 = Sunday, 2 = Monday). */
    fun startOfWeek(date: Instant, zone: ZoneId = ZoneId.systemDefault(), firstWeekday: Int = defaultFirstWeekday()): Instant =
        Instant.ofEpochMilli(uniffi.takt_core.startOfWeekMs(date.coreMillis, zone.coreName, firstWeekday.toUByte()))
}

/** The core's totals as `WorkProgress`. */
fun WorkProgress.Companion.of(totals: uniffi.takt_core.WorkProgressTotals): WorkProgress = WorkProgress(
    WorkTotals(totals.todayCompleted.toInt(), totals.todaySeconds.toInt()),
    WorkTotals(totals.weekCompleted.toInt(), totals.weekSeconds.toInt()),
    totals.elapsedDays.toInt(),
)
