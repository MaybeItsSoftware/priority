package uk.co.maybeitsadam.takt.data.workspace

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.core.TaskList
import uk.co.maybeitsadam.takt.core.TaskStatus
import uk.co.maybeitsadam.takt.core.Workspace
import uk.co.maybeitsadam.takt.data.TestWorkspace
import uniffi.takt_core.FilterDefinition
import uniffi.takt_core.FilterRule

/** Filter lists through the repository: the Rust core's `filter_lists`, as the phone reaches it. */
class WorkspaceFilterListsTest {
    private class Fixture(val w: TestWorkspace, val workspace: Workspace, val work: TaskList, val home: TaskList) {
        val store get() = w.repository
    }

    private fun fixture(test: suspend Fixture.() -> Unit): Unit = runBlocking {
        workspace().use { w ->
            val ws = w.repository.bootstrapIfNeeded()
            Fixture(w, ws, w.repository.createList(ws.id, "Work"), w.repository.createList(ws.id, "Home")).test()
        }
    }

    private fun mentions(text: String, show: String = "open") =
        FilterDefinition(matchMode = "all", show = show, rules = listOf(FilterRule("text", "contains", text)))

    @Test
    fun aFilterListIsCreatedListedAndDeletedAsUndoableSteps() = fixture {
        assertTrue(store.filterLists(workspace.id).isEmpty())

        val calls = store.createFilterList(workspace.id, "Calls", mentions("call"))
        assertEquals("New Filter List", store.undoableLabel())
        assertEquals("Open tasks where title or notes contains call", calls.summary)
        val errands = store.createFilterList(workspace.id, "Errands", mentions("buy"))
        assertEquals(listOf("Calls", "Errands"), store.filterLists(workspace.id).map { it.name })

        store.moveFilterList(errands.id, 0)
        assertEquals(listOf("Errands", "Calls"), store.observeFilterLists(workspace.id).first().map { it.name })
        assertEquals("the sidebar carries them", listOf("Errands", "Calls"), store.sidebar(workspace.id).filterLists.map { it.name })

        store.renameFilterList(calls.id, "Phone")
        assertEquals("Phone", store.filterList(calls.id)?.name)

        store.deleteFilterList(calls.id)
        assertNull(store.filterList(calls.id))
        store.undo()
        assertEquals("Phone", store.filterList(calls.id)?.name)
    }

    @Test
    fun theBuiltInListsAreReadableButNotListed() = fixture {
        val everything = store.filterList("builtin:everything")
        assertTrue(everything?.isBuiltin == true)
        assertTrue(store.filterLists(workspace.id).none { it.isBuiltin })

        val task = store.createTask(listId = work.id, title = "Anything")
        assertTrue(task.id in store.filterListTasks(workspace.id, "builtin:everything").map { it.id })
    }

    @Test
    fun aFilterListShowsItsMatchesAcrossListsInBoardOrder() = fixture {
        val ring = store.createTask(listId = home.id, title = "Call the plumber")
        store.createTask(listId = work.id, title = "Write the report")
        val client = store.createTask(listId = work.id, title = "Call the client")
        val done = store.createTask(listId = work.id, title = "Call the bank")
        store.setStatus(TaskStatus.COMPLETED, done.id)
        val calls = store.createFilterList(workspace.id, "Calls", mentions("call"))

        // Lists in sidebar order: Work was made before Home.
        assertEquals(listOf(client.id, ring.id), store.filterListTasks(workspace.id, calls.id).map { it.id })
        val scope = store.filterListScope(workspace.id, calls.id)
        assertEquals("Calls", scope.filterList?.name)
        assertEquals(listOf("Work", "Home"), scope.matches.map { it.list.name })

        val finished = store.createFilterList(workspace.id, "Finished calls", mentions("call", show = "done"))
        assertEquals(listOf(done.id), store.filterListTasks(workspace.id, finished.id).map { it.id })
    }

    @Test
    fun aMissingOrUnreadableFilterListIsAStoreError() = fixture {
        assertStoreError(WorkspaceStoreError.MISSING_FILTER_LIST) { store.filterListTasks(workspace.id, "no-such-list") }
        assertNull(store.filterListScope(workspace.id, "no-such-list").filterList)
        assertStoreError(WorkspaceStoreError.INVALID_FILTER) {
            store.createFilterList(workspace.id, "Odd", FilterDefinition("all", "open", listOf(FilterRule("mood", "is", "happy"))))
        }
        assertStoreError(WorkspaceStoreError.EMPTY_NAME) { store.createFilterList(workspace.id, "  ", mentions("x")) }
    }

    @Test
    fun theScopeRereadsWhenATaskStartsToMatch() = fixture {
        val calls = store.createFilterList(workspace.id, "Calls", mentions("call"))
        val task = store.createTask(listId = work.id, title = "Email the client")
        assertTrue(store.observeFilterListScope(workspace.id, calls.id).first().matches.isEmpty())

        val emissions = store.observeFilterListScope(workspace.id, calls.id)
        withTimeout(5_000) {
            var wrote = false
            emissions.first { scope ->
                if (!wrote) {
                    wrote = true
                    store.updateTask(task.id, "Call the client", "", null, null)
                }
                scope.matches.any { it.task.id == task.id }
            }
        }

        // Deleting the filter list empties its scope rather than failing it.
        withTimeout(5_000) {
            var deleted = false
            store.observeFilterListScope(workspace.id, calls.id).first { scope ->
                if (!deleted) {
                    deleted = true
                    store.deleteFilterList(calls.id)
                }
                scope.filterList == null
            }
        }
    }
}
