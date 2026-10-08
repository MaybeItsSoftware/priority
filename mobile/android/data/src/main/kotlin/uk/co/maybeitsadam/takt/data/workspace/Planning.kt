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

