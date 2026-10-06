package uk.co.maybeitsadam.takt.core

import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The export must be interchangeable with the Mac's, so the fixtures in
 * `resources/export` were written by Foundation's JSONEncoder (pretty printed,
 * sorted keys, ISO 8601 dates) and by the Mac's `markdown(_:)` from the same
 * snapshot as below, and the port has to match them byte for byte.
 */
class WorkspaceExportTest {
    private fun at(seconds: Double): Instant = Instant.ofEpochMilli((seconds * 1000).toLong())

    private fun task(
        id: String,
        parent: String?,
        title: String,
        notes: String = "",
        status: TaskStatus = TaskStatus.OPEN,
        sortOrder: Int,
        created: Double,
    ) = WorkspaceTask(
        id = id, listId = "L1", parentTaskId = parent, title = title, notes = notes, status = status,
        sortOrder = sortOrder, dueAt = null, estimateSeconds = null, sourceSystem = null, sourceId = null,
        itemKind = null, isPromoted = null, archivedAt = null, completedAt = null,
        createdAt = at(created), updatedAt = at(created + 1),
    )

    private val snapshot: WorkspaceExportSnapshot = run {
        val inbox = TaskList(
            id = "L1", workspaceId = "W", folderId = "F1", name = "Inbox / \"main\"", colorHex = "#007fff",
            sortOrder = 0, isArchived = false, systemRole = TaskListRole.INBOX, visibleRootTaskId = "T1",
            completedAt = at(1759700000.25), createdAt = at(1759000000.999), updatedAt = at(1759100000.0),
        )
        val old = TaskList(
            id = "L2", workspaceId = "W", folderId = null, name = "Old", colorHex = null, sortOrder = -1,
            isArchived = true, systemRole = null, visibleRootTaskId = null, completedAt = null,
            createdAt = at(0.0), updatedAt = at(1.0),
        )
        val tasks = listOf(
            task("T1", null, "Plan the week", notes = "First line\n\nSecond \\ line\ttab", sortOrder = 0, created = 1759000001.0),
            task("T2", "T1", "Draft notes é😀", status = TaskStatus.COMPLETED, sortOrder = 1, created = 1759000003.0).copy(
                dueAt = at(1759800000.0), estimateSeconds = 1800, sourceSystem = "checkvist", sourceId = "123",
                itemKind = WorkspaceItemKind.LIST, isPromoted = false, archivedAt = at(1759900000.0),
                completedAt = at(1759850000.5),
            ),
            task("T3", "T2", "Deep", notes = "only", status = TaskStatus.CANCELLED, sortOrder = 0, created = 1759000005.0)
                .copy(estimateSeconds = 0, itemKind = WorkspaceItemKind.TASK, isPromoted = true),
            task("T4", null, "Second root", sortOrder = 1, created = 1759000007.0),
        )
        WorkspaceExportSnapshot(
            exportedAt = at(1759752000.75),
            workspace = "Adam's workspace",
            lists = listOf(ExportedList(inbox, tasks), ExportedList(old, emptyList())),
        )
    }

    private fun fixture(name: String): String =
        checkNotNull(javaClass.getResource("/export/$name")) { "missing fixture $name" }.readText()

    @Test
    fun jsonMatchesWhatTheMacWrites() {
        assertEquals(fixture("workspace.json"), WorkspaceExport.document(snapshot, WorkspaceExportFormat.JSON))
    }

    @Test
    fun markdownMatchesWhatTheMacWrites() {
        assertEquals(fixture("workspace.md"), WorkspaceExport.document(snapshot, WorkspaceExportFormat.MARKDOWN))
    }

    @Test
    fun theTreeIsWalkedDepthFirstInSiblingOrder() {
        val children = mapOf(null to listOf("a", "d"), "a" to listOf("b", "c"), "b" to emptyList(), "c" to emptyList(), "d" to emptyList())
        val tree = WorkspaceExport.taskTree { parent ->
            children.getValue(parent).map { task(it, parent, it, sortOrder = 0, created = 0.0) }
        }
        assertEquals(listOf("a", "b", "c", "d"), tree.map { it.id })
    }

    @Test
    fun anEmptyWorkspaceIsWrittenAsFoundationWritesIt() {
        val empty = WorkspaceExportSnapshot(at(1759752000.0), "w", emptyList())
        assertEquals(
            "{\n  \"exportedAt\" : \"2025-10-06T12:00:00Z\",\n  \"lists\" : [\n\n  ],\n  \"workspace\" : \"w\"\n}",
            WorkspaceExport.json(empty),
        )
        assertEquals("# w\n", WorkspaceExport.markdown(empty))
    }

    @Test
    fun theSuggestedNamesMatchTheMac() {
        assertEquals("Takt workspace.md", WorkspaceExportFormat.MARKDOWN.suggestedFileName)
        assertEquals("Takt workspace.json", WorkspaceExportFormat.JSON.suggestedFileName)
    }
}
