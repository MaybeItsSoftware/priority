package uk.co.maybeitsadam.priority.data.workspace

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.priority.core.TaskStatus
import uk.co.maybeitsadam.priority.data.TestWorkspace

/**
 * Port of workspace-tests/WorkspaceSearchTests.swift.
 * `testTasksWrittenBeforeTheIndexExistedAreStillFound` is not ported: it
 * rewinds the v7 migration, which the Android side never runs.
 */
class WorkspaceSearchTest {
    private fun fixture(test: suspend (TestWorkspace, String, String) -> Unit): Unit = runBlocking {
        workspace().use { w ->
            val workspace = w.repository.bootstrapIfNeeded()
            test(w, workspace.id, w.repository.inbox(workspace.id)!!.id)
        }
    }

    @Test
    fun findsTasksByTitleAndNotes() = fixture { w, workspaceId, listId ->
        val store = w.repository
        val invoice = store.createTask(listId = listId, title = "Send the invoice")
        val unrelated = store.createTask(listId = listId, title = "Water the plants")
        store.updateTask(unrelated.id, "Water the plants", "Ask about the invoice while there", null, null)
        store.createTask(listId = listId, title = "Buy milk")

        val results = store.searchTasks(workspaceId, "invoice")
        assertEquals(listOf(invoice.id, unrelated.id), results.map { it.task.id })
        assertEquals(listId, results.first().list.id)
        assertNull(results.first().notesSnippet)
        assertEquals(true, results.last().notesSnippet?.contains("invoice"))
    }

    @Test
    fun matchesPrefixesSoResultsNarrowWhileTyping() = fixture { w, workspaceId, listId ->
        val store = w.repository
        val task = store.createTask(listId = listId, title = "Reconcile the accounts")
        assertEquals(listOf(task.id), store.searchTasks(workspaceId, "recon").map { it.task.id })
        assertEquals(listOf(task.id), store.searchTasks(workspaceId, "recon acc").map { it.task.id })
        assertTrue(store.searchTasks(workspaceId, "reconx").isEmpty())
    }

    @Test
    fun indexFollowsEditsAndDeletions() = fixture { w, workspaceId, listId ->
        val store = w.repository
        val task = store.createTask(listId = listId, title = "Draft the proposal")
        assertEquals(1, store.searchTasks(workspaceId, "proposal").size)
        store.updateTask(task.id, "Draft the summary", "", null, null)
        assertTrue(store.searchTasks(workspaceId, "proposal").isEmpty())
        assertEquals(1, store.searchTasks(workspaceId, "summary").size)
        store.deleteTask(task.id)
        assertTrue(store.searchTasks(workspaceId, "summary").isEmpty())
    }

    @Test
    fun excludesCompletedTasksAndArchivedListsUnlessAsked() = fixture { w, workspaceId, listId ->
        val store = w.repository
        val other = store.createList(workspaceId = workspaceId, name = "Old work")
        val archived = store.createTask(listId = other.id, title = "Archived report")
        val done = store.createTask(listId = listId, title = "Finished report")
        store.setStatus(TaskStatus.COMPLETED, done.id)
        store.setListArchived(true, other.id)
        assertTrue(store.searchTasks(workspaceId, "report").isEmpty())
        assertEquals(
            listOf(archived.id, done.id).sorted(),
            store.searchTasks(workspaceId, "report", includingCompleted = true, includingArchivedLists = true)
                .map { it.task.id }.sorted(),
        )
    }

    @Test
    fun ignoresAnEmptyOrUnmatchableQuery() = fixture { w, workspaceId, listId ->
        val store = w.repository
        store.createTask(listId = listId, title = "Something")
        assertTrue(store.searchTasks(workspaceId, "   ").isEmpty())
        assertTrue(store.searchTasks(workspaceId, "***").isEmpty())
    }
}
