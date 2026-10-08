package uk.co.maybeitsadam.takt.data.workspace

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import uk.co.maybeitsadam.takt.core.HabitExpiry
import uk.co.maybeitsadam.takt.core.HabitFrequency
import uk.co.maybeitsadam.takt.core.HabitPlacement
import uk.co.maybeitsadam.takt.core.HabitPolicy
import uk.co.maybeitsadam.takt.core.TaskList
import uk.co.maybeitsadam.takt.core.TaskStatus
import uk.co.maybeitsadam.takt.core.WorkspaceDaily
import uk.co.maybeitsadam.takt.core.WorkspaceItemKind
import uk.co.maybeitsadam.takt.core.WorkspaceTask
import uk.co.maybeitsadam.takt.data.db.Db

// Habits (WorkspaceStore+Habits.swift): dailies made through the habit form.
// A habit is still one task with one daily attached; ticking it logs a
// contribution and never completes the task. What a habit adds is a column
// each appearance lands in, a choice about missed days, and an end.
// `HabitPolicy` in :core decides all three; this file applies them, row for
// row as the Mac does. The engine only ever writes to rows that already exist
// (the daily, and the task's metadata keyed by task id), so the Mac and this
// device running it on the same habit write the same rows and sync merges
// them; the one row it can create, the Habits list, has an id both derive.

/** What the habit form edits. */
data class HabitDraft(
    val title: String,
    val frequency: HabitFrequency = HabitFrequency.Daily,
    val dropsAtDayEnd: Boolean = true,
    val estimateSeconds: Int? = null,
    val expiry: HabitExpiry = HabitExpiry.Never,
    val placement: HabitPlacement = HabitPlacement.TODAY,
    /** The task the habit came from. Null for a standalone habit. */
    val sourceTaskId: String? = null,
) {
    companion object {
        /** A fresh draft: one made from a task ends with that task. */
        fun new(title: String, sourceTaskId: String? = null) = HabitDraft(
            title = title,
            expiry = if (sourceTaskId == null) HabitExpiry.Never else HabitExpiry.WhenSourceCompleted,
            sourceTaskId = sourceTaskId,
        )
    }
}

/** What the form opens on: a fresh draft for a new habit, or the stored one. */
data class HabitFormContext(
    /** The task the habit lives on, when editing one. */
    val habitTaskId: String?,
    val draft: HabitDraft,
    /** For "when <source> is done". */
    val sourceTitle: String?,
)

/**
 * What the habit form should open on for [taskId]. A task that already
 * carries a daily is edited in place (a plain daily becoming a habit on
 * save); any other task is the source of a new habit; no task at all is a
 * standalone habit.
 */
suspend fun WorkspaceRepository.habitFormContext(taskId: String?): HabitFormContext = database.read { db ->
    val task = taskId?.let { db.task(it) } ?: return@read HabitFormContext(null, HabitDraft.new(""), null)
    val daily = db.queryOne("SELECT * FROM dailies WHERE taskId = ? AND archivedAt IS NULL", task.id) { it.toDaily() }
    if (daily != null) {
        val source = daily.sourceTaskId?.let { db.task(it) }
        val draft = HabitDraft(
            title = task.title, frequency = daily.frequency, dropsAtDayEnd = daily.dropsAtDayEnd,
            estimateSeconds = daily.targetSeconds ?: task.estimateSeconds, expiry = daily.expiry,
            placement = daily.placement ?: HabitPlacement.TODAY, sourceTaskId = daily.sourceTaskId,
        )
        return@read HabitFormContext(task.id, draft, source?.title)
    }
    HabitFormContext(null, HabitDraft.new(task.title, task.id), task.title)
}

/** Every task whose daily is a habit: the ones ticked for the day rather than closed. */
suspend fun WorkspaceRepository.habitTaskIds(): Set<String> = database.read { db ->
    db.strings("SELECT taskId FROM dailies WHERE archivedAt IS NULL AND placementColumn IS NOT NULL").toSet()
}

/**
 * Creates a habit, or rewrites the one on [habitTaskId]. A new habit is a
 * task in the Habits list, beside the task it came from rather than under
 * it, so finishing the source is not blocked by a child that recurs forever.
 * It lands in its column straight away if it is due today. One undo step.
 */
suspend fun WorkspaceRepository.saveHabit(
    draft: HabitDraft,
    habitTaskId: String? = null,
    now: Instant = now(),
    zone: ZoneId = this.zone,
): WorkspaceDaily {
    // The Rust core's `habits::save_habit`, with the schedule as a daily stores it.
    val schedule = draft.frequency.storage
    val core = uniffi.takt_core.HabitDraft(
        title = draft.title,
        weekdays = schedule.weekdays.sorted().map { it.toUInt() },
        intervalDays = schedule.intervalDays?.toLong(),
        dropsAtDayEnd = draft.dropsAtDayEnd,
        estimateSeconds = draft.estimateSeconds?.toLong(),
        expiryRule = draft.expiry.rule,
        expiresAtMs = draft.expiry.date?.toEpochMilli(),
        placement = draft.placement.raw,
        sourceTaskId = draft.sourceTaskId,
    )
    val id = coreWrite { it.saveHabit(core, habitTaskId, now.toEpochMilli(), zone.id) }
    return database.read { it.daily(id) } ?: fail(WorkspaceStoreError.MISSING_DAILY)
}

/**
 * Applies every habit's options for [now]: expired habits are archived, a due
 * appearance is put in its column, and one that is done, dropped at the end
 * of its day, or no longer due is taken out of it.
 *
 * Not an undo step, as on the Mac: nobody asked for it, and undoing it would
 * only put back a card the next pass takes out again. A read first, so the
 * pass that finds no habits never takes the writer. Returns whether anything
 * changed.
 */
suspend fun WorkspaceRepository.reconcileHabits(now: Instant = now(), zone: ZoneId = this.zone): Boolean {
    val pending = database.read { db ->
        db.strings("SELECT id FROM dailies WHERE archivedAt IS NULL AND placementColumn IS NOT NULL")
    }
    if (pending.isEmpty()) return false
    // The Rust core's `habits::reconcile_habits`, outside the journal.
    return coreWrite { it.reconcileHabits(now.toEpochMilli(), zone.id) }
}

/** Whether a habit is showing on [day]: scheduled, or carried over from a missed day it does not drop. */
internal fun habitShows(db: Db, daily: WorkspaceDaily, day: Instant, zone: ZoneId): Boolean {
    val rule = daily.habitRule
    val sourceCompleted = isSourceCompleted(db, daily)
    if (HabitPolicy.isExpired(rule, day, sourceCompleted, zone)) return false
    if (HabitPolicy.isScheduled(rule, day, zone)) return true
    return HabitPolicy.appearance(rule, day, lastDoneDay(db, daily.id, zone), sourceCompleted, zone) != null
}

/** What `dailies(on:)` and next-up ask of a daily: due for a plain one, showing for a habit. */
internal fun dailyShows(db: Db, daily: WorkspaceDaily, day: Instant, zone: ZoneId): Boolean =
    if (daily.isHabit) habitShows(db, daily, day, zone) else daily.isDue(day, zone)

/** A source that is closed or gone has ended. */
private fun isSourceCompleted(db: Db, daily: WorkspaceDaily): Boolean {
    val sourceId = daily.sourceTaskId ?: return false
    val source = db.task(sourceId) ?: return true
    return source.status != TaskStatus.OPEN
}

private fun lastDoneDay(db: Db, dailyId: String, zone: ZoneId): Instant? {
    val key = db.string(
        "SELECT MAX(dayKey) FROM daily_contributions WHERE dailyId = ? AND completedAt IS NOT NULL", dailyId,
    ) ?: return null
    val parts = key.split("-").mapNotNull { it.toIntOrNull() }
    if (parts.size != 3) return null
    return runCatching { LocalDate.of(parts[0], parts[1], parts[2]).atStartOfDay(zone).toInstant() }.getOrNull()
}

private fun startOfDay(instant: Instant, zone: ZoneId): Instant =
    instant.atZone(zone).toLocalDate().atStartOfDay(zone).toInstant()

internal fun kanbanColumn(db: Db, taskId: String): String? =
    db.string("SELECT kanbanColumn FROM task_metadata WHERE taskId = ?", taskId)

/** Taking a card out of a column also drops its place in the day, as `setPlannedForToday` does. */
internal fun writeKanbanColumn(db: Db, taskId: String, column: String?, now: Instant) {
    db.execute(
        "INSERT INTO task_metadata(taskId, tagsJSON, externalLinksJSON, kanbanColumn, updatedAt) " +
            "VALUES (?, '[]', '[]', ?, ?) ON CONFLICT(taskId) DO UPDATE SET " +
            "kanbanColumn = excluded.kanbanColumn, " +
            "focusRank = CASE WHEN excluded.kanbanColumn IS NULL THEN NULL ELSE focusRank END, " +
            "updatedAt = excluded.updatedAt",
        taskId, column, now,
    )
}
