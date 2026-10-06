package uk.co.maybeitsadam.takt.data.workspace

import java.time.Instant
import uk.co.maybeitsadam.takt.core.ExportedList
import uk.co.maybeitsadam.takt.core.WorkspaceExport
import uk.co.maybeitsadam.takt.core.WorkspaceExportSnapshot

// The workspace written out to a file, as Takt/WorkspaceViewModel+Export.swift
// reads it: every list, archived included, in the sidebar's order, each with
// its whole task tree depth first in the outline's order.

/** A snapshot of [workspaceId] for [WorkspaceExport], read in one transaction. */
suspend fun WorkspaceRepository.exportSnapshot(workspaceId: String, now: Instant = Instant.now()): WorkspaceExportSnapshot =
    database.read { db ->
        val workspace = db.workspace(workspaceId) ?: error("The workspace is not open, so there is nothing to export.")
        WorkspaceExportSnapshot(
            exportedAt = now,
            workspace = workspace.name,
            lists = listsIn(db, workspaceId, includingArchived = true).map { list ->
                ExportedList(list, WorkspaceExport.taskTree { parent -> db.taskSiblings(list.id, parent, withId = false) })
            },
        )
    }
