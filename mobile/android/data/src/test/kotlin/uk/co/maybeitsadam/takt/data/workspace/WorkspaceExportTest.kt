package uk.co.maybeitsadam.takt.data.workspace

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.core.WorkspaceExportFormat

/** What the export reads: every list, archived included, each with its tree depth first. */
class WorkspaceExportTest {
    @Test
    fun theDocumentHoldsEveryListWithItsTreeDepthFirst() = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val ws = store.bootstrapIfNeeded()
            val work = store.createList(ws.id, "Work")
            val old = store.createList(ws.id, "Old")
            store.setListArchived(true, old.id)
            val report = store.createTask(listId = work.id, title = "Report")
            store.createTask(listId = work.id, title = "Send")
            store.createTask(listId = work.id, title = "Draft", parentTaskId = report.id)
            store.createTask(listId = old.id, title = "Gone")

            val markdown = store.exportDocument(ws.id, WorkspaceExportFormat.MARKDOWN, now = epoch(0))

            val inbox = store.lists(ws.id, includingArchived = true).first { it.id != work.id && it.id != old.id }
            assertEquals(
                "# ${ws.name}\n\n## ${inbox.name}\n\n\n## Work\n\n- [ ] Report\n  - [ ] Draft\n- [ ] Send\n\n" +
                    "## Old (archived)\n\n- [ ] Gone\n",
                markdown,
            )
            val json = store.exportDocument(ws.id, WorkspaceExportFormat.JSON, now = epoch(0))
            assertTrue(json.startsWith("{\n  \"exportedAt\" : \"1970-01-01T00:00:00Z\",\n  \"lists\" : [\n"))
        }
    }
}
