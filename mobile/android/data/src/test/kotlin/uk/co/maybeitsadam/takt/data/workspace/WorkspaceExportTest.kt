package uk.co.maybeitsadam.takt.data.workspace

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

/** What the export reads: every list, archived included, each with its tree depth first. */
class WorkspaceExportTest {
    @Test
    fun theSnapshotHoldsEveryListWithItsTreeDepthFirst() = runBlocking {
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

            val snapshot = store.exportSnapshot(ws.id, now = epoch(0))

            assertEquals(ws.name, snapshot.workspace)
            assertEquals(store.lists(ws.id, includingArchived = true).map { it.id }, snapshot.lists.map { it.list.id })
            val byName = snapshot.lists.associate { it.list.name to it.tasks.map { task -> task.title } }
            assertEquals(listOf("Report", "Draft", "Send"), byName.getValue("Work"))
            assertEquals(listOf("Gone"), byName.getValue("Old"))
        }
    }
}
