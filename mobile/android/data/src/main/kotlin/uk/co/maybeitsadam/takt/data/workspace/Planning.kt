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

/** The Rust core's `editor::snapshot`, which the Mac and iPhone read too. */
internal fun taskEditorSnapshot(db: Db, taskId: String): TaskEditorSnapshot = try {
    db.core.editorSnapshot(taskId).toSnapshot()
} catch (_: uniffi.takt_core.CoreException.MissingTask) {
    fail(WorkspaceStoreError.MISSING_TASK)
}

