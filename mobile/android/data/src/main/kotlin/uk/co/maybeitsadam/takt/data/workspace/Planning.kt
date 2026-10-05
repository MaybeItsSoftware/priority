package uk.co.maybeitsadam.takt.data.workspace

import java.time.Instant
import java.time.ZoneId
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import uk.co.maybeitsadam.takt.core.TaskCalendarDate
import uk.co.maybeitsadam.takt.core.TaskEditorMetadata
import uk.co.maybeitsadam.takt.core.TaskMetadata
import uk.co.maybeitsadam.takt.core.TaskPlanning
import uk.co.maybeitsadam.takt.core.TaskPlanningError
import uk.co.maybeitsadam.takt.core.TaskPlanningException
import uk.co.maybeitsadam.takt.core.WorkspaceDaily
import uk.co.maybeitsadam.takt.data.db.Db

// The planning half of WorkspaceStore+Conditions.swift and the editor half of
// WorkspaceStore+Editing.swift.

internal fun planningFail(error: TaskPlanningError): Nothing = throw TaskPlanningException(error)

/** The task's planning: the stored JSON with the metadata's `startAt`, normalised. */
internal fun planning(metadata: TaskMetadata?): TaskPlanning? {
    val stored = metadata?.planningJSON?.let { TaskPlanning.fromJson(it) } ?: TaskPlanning()
    return stored.copy(startAt = metadata?.startAt).normalized
}

internal fun taskEditorSnapshot(db: Db, taskId: String): TaskEditorSnapshot {
    val task = db.task(taskId) ?: fail(WorkspaceStoreError.MISSING_TASK)
    val list = db.list(task.listId) ?: fail(WorkspaceStoreError.MISSING_TASK)
    val record = db.metadata(taskId)
    val metadata = record?.let {
        TaskEditorMetadata(
            priority = it.priority, tags = decodeStringArray(it.tagsJSON), recurrenceRule = it.recurrenceRule,
            externalLinks = decodeStringArray(it.externalLinksJSON),
        )
    } ?: TaskEditorMetadata()
    val daily = db.exists("SELECT 1 FROM dailies WHERE taskId = ? AND archivedAt IS NULL", taskId)
    return TaskEditorSnapshot(
        workspaceId = list.workspaceId, taskId = taskId, title = task.title, notes = task.notes, dueAt = task.dueAt,
        estimateSeconds = task.estimateSeconds, metadata = metadata, dailyProgress = daily,
        planning = planning(record),
    )
}

internal fun updateTaskRecord(db: Db, edit: TaskEditorSnapshot, now: Instant) {
    val task = db.task(edit.taskId) ?: fail(WorkspaceStoreError.MISSING_TASK)
    if (task.title == edit.title && task.notes == edit.notes && task.dueAt == edit.dueAt &&
        task.estimateSeconds == edit.estimateSeconds
    ) {
        return
    }
    db.update(
        task.copy(
            title = edit.title, notes = edit.notes, dueAt = edit.dueAt, estimateSeconds = edit.estimateSeconds,
            updatedAt = now,
        ),
    )
}

internal fun updateEditorMetadata(db: Db, taskId: String, metadata: TaskEditorMetadata, now: Instant) {
    db.task(taskId) ?: fail(WorkspaceStoreError.MISSING_TASK)
    val tags = normalizedStrings(metadata.tags)
    val links = normalizedStrings(metadata.externalLinks)
    val recurrence = metadata.recurrenceRule?.trimmedWhitespace()?.takeIf { it.isNotEmpty() }
    val priority = metadata.priority?.takeIf { it in 1..4 }
    val existing = db.metadata(taskId)
    val record = existing ?: emptyMetadata(taskId, now)
    if (record.priority == priority && decodeStringArray(record.tagsJSON) == tags &&
        record.recurrenceRule == recurrence && decodeStringArray(record.externalLinksJSON) == links
    ) {
        return
    }
    val updated = record.copy(
        priority = priority, tagsJSON = encodeStringArray(tags), recurrenceRule = recurrence,
        externalLinksJSON = encodeStringArray(links), updatedAt = now,
    )
    if (existing == null) db.insert(updated) else db.update(updated)
}

internal fun updatePlanning(
    db: Db,
    edit: TaskEditorSnapshot,
    previous: TaskPlanning?,
    previousDueAt: Instant? = null,
    now: Instant,
    zone: ZoneId = ZoneId.systemDefault(),
) {
    val planning = edit.planning ?: TaskPlanning()
    val dueDate = planning.dueDate
    if (dueDate != null && TaskCalendarDate.date(dueDate, zone) == null) planningFail(TaskPlanningError.INVALID_DATE)
    val deadline = dueDate?.let { TaskCalendarDate.date(it, zone) }
        ?.let { it.atZone(zone).plusDays(1).toInstant() } ?: edit.dueAt
    val changedSchedule = planning.startAt != previous?.startAt || planning.dueDate != previous?.dueDate ||
        edit.dueAt != previousDueAt
    val start = planning.startAt
    if (changedSchedule && start != null && deadline != null && start >= deadline) {
        planningFail(TaskPlanningError.INVALID_SCHEDULE)
    }
    planning.minimumBlockSeconds?.let { if (it < 60) planningFail(TaskPlanningError.INVALID_MINIMUM) }
    if (planning.requiresSingleSitting == true) {
        val estimate = edit.estimateSeconds
        if (estimate == null || estimate <= 0 || estimate < (planning.minimumBlockSeconds ?: 60)) {
            planningFail(TaskPlanningError.ESTIMATE_REQUIRED)
        }
    }
    val groups = planning.requirementGroups ?: emptyList()
    if (groups.map { it.sorted() }.toSet().size != groups.size) planningFail(TaskPlanningError.INVALID_CONDITION)
    for (group in groups) {
        if (group.isEmpty() || group.toSet().size != group.size) planningFail(TaskPlanningError.INVALID_CONDITION)
        for (id in group) {
            val condition = db.condition(id)
            val wasRequired = (previous?.requirementGroups ?: emptyList()).any { id in it }
            if (condition == null || condition.workspaceId != edit.workspaceId ||
                (condition.isArchived && !wasRequired)
            ) {
                planningFail(TaskPlanningError.INVALID_CONDITION)
            }
        }
    }
    val existing = db.metadata(edit.taskId)
    val record = existing ?: emptyMetadata(edit.taskId, now)
    val json = planning.copy(startAt = null).normalized?.let { it.toJson() }
    if (planning(record) == edit.planning) return
    val updated = record.copy(startAt = planning.startAt, planningJSON = json, updatedAt = now)
    if (existing == null) db.insert(updated) else db.update(updated)
}

internal fun setDailyAttachment(db: Db, taskId: String, enabled: Boolean, estimateSeconds: Int?, now: Instant) {
    val existing = db.queryOne("SELECT * FROM dailies WHERE taskId = ?", taskId) { it.toDaily() }
    val isEnabled = existing?.let { it.archivedAt == null } ?: false
    if (isEnabled == enabled) return
    if (enabled) makeDailyRecord(db, taskId, targetSeconds = estimateSeconds, now = now) else archiveDailyRecord(db, taskId, now)
}

internal fun makeDailyRecord(
    db: Db,
    taskId: String,
    weekdays: Set<Int> = (1..7).toSet(),
    intervalDays: Int? = null,
    targetSeconds: Int?,
    now: Instant,
): WorkspaceDaily {
    db.task(taskId) ?: fail(WorkspaceStoreError.MISSING_TASK)
    db.queryOne("SELECT * FROM dailies WHERE taskId = ?", taskId) { it.toDaily() }?.let { existing ->
        val target = targetSeconds ?: existing.targetSeconds
        if (existing.archivedAt != null || existing.targetSeconds != target) {
            val updated = existing.copy(archivedAt = null, targetSeconds = target, updatedAt = now)
            db.update(updated)
            return updated
        }
        return existing
    }
    val order = db.int("SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM dailies") ?: 0
    val daily = WorkspaceDaily.make(
        id = newId(), taskId = taskId, activeWeekdaysMask = WorkspaceDaily.mask(weekdays), intervalDays = intervalDays,
        intervalAnchor = if (intervalDays == null) null else now, targetSeconds = targetSeconds, sortOrder = order,
        archivedAt = null, createdAt = now, updatedAt = now,
    )
    db.insert(daily)
    return daily
}

internal fun archiveDailyRecord(db: Db, taskId: String, now: Instant) {
    val daily = db.queryOne("SELECT * FROM dailies WHERE taskId = ? AND archivedAt IS NULL", taskId) { it.toDaily() }
        ?: return
    db.update(daily.copy(archivedAt = now, updatedAt = now))
}
