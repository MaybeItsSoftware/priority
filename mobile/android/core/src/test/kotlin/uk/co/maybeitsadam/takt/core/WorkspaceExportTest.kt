package uk.co.maybeitsadam.takt.core

import org.junit.Assert.assertEquals
import org.junit.Test
import uniffi.takt_core.ExportFormat

/** The document is the core's, tested there against the Mac's own files. */
class WorkspaceExportTest {
    @Test
    fun theSuggestedNamesMatchTheMac() {
        assertEquals("Takt workspace.md", WorkspaceExportFormat.MARKDOWN.suggestedFileName)
        assertEquals("Takt workspace.json", WorkspaceExportFormat.JSON.suggestedFileName)
    }

    @Test
    fun eachFormatAsksTheCoreForItself() {
        assertEquals(ExportFormat.MARKDOWN, WorkspaceExportFormat.MARKDOWN.core)
        assertEquals(ExportFormat.JSON, WorkspaceExportFormat.JSON.core)
    }
}
