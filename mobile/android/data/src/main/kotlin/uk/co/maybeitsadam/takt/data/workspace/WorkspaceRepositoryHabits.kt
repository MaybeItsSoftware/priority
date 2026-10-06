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
    val title = nonEmptyName(draft.title)
    return journalledWrite(if (habitTaskId == null) "New Habit" else "Edit Habit") { db ->
        val task: WorkspaceTask
        if (habitTaskId != null) {
            val existing = db.task(habitTaskId) ?: fail(WorkspaceStoreError.MISSING_TASK)
            task = if (existing.title != title || existing.estimateSeconds != draft.estimateSeconds) {
                existing.copy(title = title, estimateSeconds = draft.estimateSeconds, updatedAt = now).also { db.update(it) }
            } else {
                existing
            }
        } else {
            val workspaceId = db.strings("SELECT id FROM workspaces LIMIT 1").firstOrNull()
                ?: fail(WorkspaceStoreError.MISSING_LIST)
            val habits = habitsList(db, workspaceId, now)
            val order = db.int(
                "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM tasks WHERE listId = ? AND parentTaskId IS NULL", habits.id,
            ) ?: 0
            task = WorkspaceTask(
                id = newId(), listId = habits.id, parentTaskId = null, title = title, notes = "",
                status = TaskStatus.OPEN, sortOrder = order, dueAt = null, estimateSeconds = draft.estimateSeconds,
                sourceSystem = null, sourceId = null, itemKind = WorkspaceItemKind.TASK, isPromoted = null,
                archivedAt = null, completedAt = null, createdAt = now, updatedAt = now,
            )
            db.insert(task)
        }

        var daily = makeDailyRecord(db, task.id, targetSeconds = draft.estimateSeconds, now = now)
        val previousPlacement = daily.placementColumn
        val schedule = draft.frequency.storage
        // A habit is anchored on the day it was made, so "every 3 days" and
        // "weekly" count from then, and nothing is owed from before it.
        val anchor = if (daily.intervalDays != schedule.intervalDays || daily.intervalAnchor == null) {
            startOfDay(daily.intervalAnchor ?: now, zone)
        } else {
            daily.intervalAnchor
        }
        daily = daily.copy(
            activeWeekdaysMask = WorkspaceDaily.mask(schedule.weekdays),
            intervalAnchor = anchor,
            intervalDays = schedule.intervalDays,
            targetSeconds = draft.estimateSeconds,
            sourceTaskId = draft.sourceTaskId,
            placementColumn = draft.placement.raw,
            dropsAtDayEnd = draft.dropsAtDayEnd,
            expiryRule = draft.expiry.rule,
            expiresAt = draft.expiry.date?.let { startOfDay(it, zone) },
            updatedAt = now,
        )
        db.update(daily)

        // Moving a habit to another column takes its card along.
        if (previousPlacement != null && previousPlacement != daily.placementColumn &&
            kanbanColumn(db, task.id) == previousPlacement
        ) {
            writeKanbanColumn(db, task.id, null, now)
        }
        reconcileHabit(db, daily, now, zone)
        db.daily(daily.id) ?: daily
    }
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
    return database.write { db ->
        var changed = false
        for (id in pending) {
            val current = db.daily(id)?.takeIf { !it.isArchived } ?: continue
            if (reconcileHabit(db, current, now, zone)) changed = true
        }
        changed
    }
}

/** One habit's pass. See [reconcileHabits]. */
internal fun reconcileHabit(db: Db, daily: WorkspaceDaily, now: Instant, zone: ZoneId): Boolean {
    val placement = daily.placement ?: return false
    val task = db.task(daily.taskId)?.takeIf { it.status == TaskStatus.OPEN } ?: return false
    val rule = daily.habitRule
    val sourceCompleted = isSourceCompleted(db, daily)
    val current = kanbanColumn(db, task.id)
    if (HabitPolicy.isExpired(rule, now, sourceCompleted, zone)) {
        db.update(daily.copy(archivedAt = now, updatedAt = now))
        if (current == placement.raw) writeKanbanColumn(db, task.id, null, now)
        return true
    }
    val appearance = HabitPolicy.appearance(rule, now, lastDoneDay(db, daily.id, zone), sourceCompleted, zone)
    val change = HabitPolicy.reconciledColumn(current, appearance, placement) ?: return false
    writeKanbanColumn(db, task.id, change.column, now)
    return true
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

/**
 * Ends every habit made from [sourceTaskId] that ends with it. Called from
 * each place a task is closed, inside that write, so undoing the completion
 * brings the habits back with it.
 */
internal fun expireHabits(db: Db, sourceTaskId: String, now: Instant) {
    val habits = db.query(
        "SELECT * FROM dailies WHERE sourceTaskId = ? AND archivedAt IS NULL AND expiryRule = ?",
        sourceTaskId, HabitExpiry.WhenSourceCompleted.rule,
    ) { it.toDaily() }
    for (habit in habits) {
        db.update(habit.copy(archivedAt = now, updatedAt = now))
        val column = habit.placementColumn
        if (column != null && kanbanColumn(db, habit.taskId) == column) writeKanbanColumn(db, habit.taskId, null, now)
    }
}

/**
 * The Habits list, made if there is none. Looked up by its derived id first,
 * then by name (a list the Mac made before ids were derived).
 */
internal fun habitsList(db: Db, workspaceId: String, now: Instant): TaskList {
    val id = HabitPolicy.habitsListId(workspaceId)
    db.list(id)?.let { return it }
    db.queryOne(
        "SELECT * FROM task_lists WHERE workspaceId = ? AND name = ?", workspaceId, HabitPolicy.HABITS_LIST_NAME,
    ) { it.toList() }?.let { return it }
    val order = db.int("SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM task_lists WHERE workspaceId = ?", workspaceId) ?: 0
    return TaskList(
        id = id, workspaceId = workspaceId, folderId = null, name = HabitPolicy.HABITS_LIST_NAME, colorHex = null,
        sortOrder = order, isArchived = false, systemRole = null, visibleRootTaskId = null, completedAt = null,
        createdAt = now, updatedAt = now,
    ).also { db.insert(it) }
}

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
