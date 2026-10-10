package uk.co.maybeitsadam.takt.core

import uniffi.takt_core.ExportFormat

// The document itself is the Rust core's (`core/src/export.rs`), the same
// bytes the Mac writes, read and built in one call; what stays here is what
// the save dialog needs to know about each format.

/** The two formats the workspace is written out in. */
enum class WorkspaceExportFormat(val title: String, val fileExtension: String, val mimeType: String) {
    MARKDOWN("Markdown", "md", "text/markdown"),
    JSON("JSON", "json", "application/json");

    /** The name the save dialog suggests, as on the Mac. */
    val suggestedFileName: String get() = "Takt workspace.$fileExtension"

    /** The format as the core's export takes it. */
    val core: ExportFormat get() = if (this == MARKDOWN) ExportFormat.MARKDOWN else ExportFormat.JSON
}
