package uk.co.maybeitsadam.takt.data.workspace

import java.time.Instant
import uk.co.maybeitsadam.takt.core.WorkspaceExportFormat
import uk.co.maybeitsadam.takt.core.coreMillis

/**
 * The workspace [workspaceId] written out as [format]: every list, archived
 * included, in the sidebar's order, each with its whole task tree depth
 * first. The Rust core's `export::export` reads and writes it in one call,
 * byte for byte the file the Mac writes, so no row crosses.
 */
suspend fun WorkspaceRepository.exportDocument(
    workspaceId: String,
    format: WorkspaceExportFormat,
    now: Instant = Instant.now(),
): String = database.read { db ->
    db.core.exportWorkspace(workspaceId, format.core, now.coreMillis)
        ?: error("The workspace is not open, so there is nothing to export.")
}
