package uk.co.maybeitsadam.takt.data.workspace

import uk.co.maybeitsadam.takt.core.TaskPlanningError
import uk.co.maybeitsadam.takt.core.TaskPlanningException
import uk.co.maybeitsadam.takt.data.db.Db

// The planning half of WorkspaceStore+Conditions.swift and the editor half of
// WorkspaceStore+Editing.swift.

internal fun planningFail(error: TaskPlanningError): Nothing = throw TaskPlanningException(error)

/** The Rust core's `editor::snapshot`, which the Mac and iPhone read too. */
internal fun taskEditorSnapshot(db: Db, taskId: String): TaskEditorSnapshot = try {
    db.core.editorSnapshot(taskId).toSnapshot()
} catch (_: uniffi.takt_core.CoreException.MissingTask) {
    fail(WorkspaceStoreError.MISSING_TASK)
}

