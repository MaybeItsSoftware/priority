package uk.co.maybeitsadam.takt.data.workspace

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.core.TaskEditorMetadata
import uk.co.maybeitsadam.takt.core.TaskMatrixPosition

/** The Lists screens' reads: a scope with its decorations, and the sidebar's raw material. */
class WorkspaceListsReadTest {
    @Test
    fun aListScopeCarriesItsTreeAndDecorations() = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val ws = store.bootstrapIfNeeded()
            val list = store.createList(ws.id, "Work")
            val task = store.createTask(listId = list.id, title = "Report")
            store.createTask(listId = list.id, title = "Draft", parentTaskId = task.id)
            store.updateTaskEditorMetadata(task.id, TaskEditorMetadata(priority = 2, tags = listOf("deep")))
            store.setKanbanColumn("today", task.id)
            store.setMatrixPosition(TaskMatrixPosition(1, 0), task.id)
            store.makeDaily(task.id)

            val scope = store.listScope(ws.id, list.id)
            assertEquals(listOf(list.id), scope.lists.map { it.id })
            assertEquals(listOf("Report", "Draft"), scope.trees.getValue(list.id).outline().map { it.task.title })
            val decoration = scope.decorations.getValue(task.id)
            assertEquals(2, decoration.priority)
            assertEquals(listOf("deep"), decoration.tags)
            assertEquals("today", decoration.kanbanColumn)
            assertEquals(1, decoration.matrixUrgency)
            assertEquals(0, decoration.matrixImportance)
            assertTrue(task.id in scope.dailyTaskIds)
        }
    }

    @Test
    fun everythingSkipsArchivedAndCompletedLists() = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val ws = store.bootstrapIfNeeded()
            val open = store.createList(ws.id, "Open")
            val archived = store.createList(ws.id, "Archived")
            val done = store.createList(ws.id, "Done")
            store.setListArchived(true, archived.id)
            store.setListCompleted(true, done.id)

            val scope = store.listScope(ws.id, null)
            val ids = scope.lists.map { it.id }
            assertTrue(open.id in ids)
            assertFalse(archived.id in ids)
            assertFalse(done.id in ids)
            assertTrue(done.id in scope.allLists.map { it.id })
        }
    }

    @Test
    fun theSidebarHasArchivedListsButOnlyActiveTrees() = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val ws = store.bootstrapIfNeeded()
            val folder = store.createFolder(ws.id, "Projects")
            val list = store.createList(ws.id, "Garden", folder.id)
            val archived = store.createList(ws.id, "Old")
            store.setListArchived(true, archived.id)
            store.createTask(listId = list.id, title = "Dig")

            val sidebar = store.sidebar(ws.id)
            assertEquals(listOf("Projects"), sidebar.folders.map { it.name })
            assertTrue(archived.id in sidebar.lists.map { it.id })
            assertFalse(archived.id in sidebar.trees.keys)
            assertEquals(1, sidebar.trees.getValue(list.id).tasks.size)
        }
    }

    @Test
    fun theScopeFlowRereadsAfterAMetadataWrite() = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val ws = store.bootstrapIfNeeded()
            val list = store.createList(ws.id, "Work")
            val task = store.createTask(listId = list.id, title = "Report")
            assertEquals(null, store.observeListScope(ws.id, list.id).first().decorations[task.id]?.priority)
            store.updateTaskEditorMetadata(task.id, TaskEditorMetadata(priority = 1))
            assertEquals(1, store.observeListScope(ws.id, list.id).first().decorations[task.id]?.priority)
        }
    }
}
