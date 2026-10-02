package uk.co.maybeitsadam.priority.data.workspace

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import uk.co.maybeitsadam.priority.data.TestWorkspace

/**
 * Port of workspace-tests/WorkspaceOrganisationTests.swift. The imported lists
 * are written by [importedList] rather than `importTasks`.
 * `testWrapperRecognitionPreservesUnicodeAndDoesNotMatchUnrelatedEmojiNames` is
 * not ported: it tests `registerVisibleRoot`, which only import runs.
 */
class WorkspaceOrganisationTest {
    private class Fixture(val w: TestWorkspace, val workspaceId: String, val inboxId: String) {
        val store get() = w.repository
    }

    private fun fixture(test: suspend Fixture.() -> Unit): Unit = runBlocking {
        workspace().use { w ->
            val workspaceId = w.repository.bootstrapIfNeeded().id
            Fixture(w, workspaceId, w.repository.inbox(workspaceId)!!.id).test()
        }
    }

    @Test
    fun renamingEitherSideOfAnImportedWrapperKeepsVisiblePlacementAfterReopenAndUndo() = fixture {
        val list = w.importedList(workspaceId, "Work")
        val rootId = store.visibleRootParentTaskId(list)!!
        val child = store.tasks(list.id, rootId).first()

        store.renameList(list.id, "Clients")
        assertEquals(rootId, store.visibleRootParentTaskId(list))
        assertEquals(listOf(child.id), store.visibleRootTasks(workspaceId).map { it.id })
        store.updateTask(rootId, "Renamed project", "", null, null)
        w.reopened { reopened ->
            assertEquals(listOf(child.id), reopened.visibleRootTasks(workspaceId).map { it.id })
            reopened.undo()
            reopened.undo()
            assertEquals(rootId, reopened.visibleRootParentTaskId(list))
            assertEquals(rootId, reopened.task(child.id)?.parentTaskId)
        }
    }

    @Test
    fun anOrdinaryTaskWithTheListNameIsVisibleEvenWhenItHasChildren() = fixture {
        val list = store.createList(workspaceId = workspaceId, name = "Project")
        val root = store.createTask(listId = list.id, title = "Project")
        store.createTask(listId = list.id, title = "Step", parentTaskId = root.id)
        assertNull(store.visibleRootParentTaskId(list))
        assertEquals(listOf(root.id), store.visibleRootTasks(workspaceId).map { it.id })
    }

    @Test
    fun movingIntoAnImportedListPlacesTheWholeSubtreeBesideVisibleWorkAndUndoesTogether() = fixture {
        val destination = w.importedList(workspaceId, "Work")
        val rootId = destination.visibleRootTaskId!!
        val existing = store.tasks(destination.id, rootId).first()
        val task = store.createTask(listId = inboxId, title = "New project")
        val child = store.createTask(listId = inboxId, title = "Step", parentTaskId = task.id)

        store.moveTask(id = task.id, toListId = destination.id, toVisibleRoot = true)

        assertEquals(listOf(existing.id, task.id), store.visibleRootTasks(workspaceId).map { it.id })
        assertEquals(destination.id, store.task(child.id)?.listId)
        assertEquals(task.id, store.task(child.id)?.parentTaskId)
        assertEquals("Move Task", store.undo())
        assertEquals(inboxId, store.task(task.id)?.listId)
        assertNull(store.task(task.id)?.parentTaskId)
        assertEquals(inboxId, store.task(child.id)?.listId)
    }

    @Test
    fun promotingAChildOrMovingTheWrapperNeverHidesOtherRoots() = fixture {
        val list = w.importedList(workspaceId, "Work")
        val rootId = list.visibleRootTaskId!!
        val child = store.tasks(list.id, rootId).first()
        store.outdentTask(child.id)
        assertNull(store.visibleRootParentTaskId(list))
        assertEquals(listOf(rootId, child.id), store.visibleRootTasks(workspaceId).map { it.id })
        store.undo()
        store.moveTask(id = rootId, toListId = inboxId)
        assertNull(store.visibleRootParentTaskId(list))
        assertEquals(listOf(rootId), store.visibleRootTasks(workspaceId).map { it.id })
    }

    @Test
    fun deletingAndRestoringAnImportedListRestoresItsWrapperIdentity() = fixture {
        val list = w.importedList(workspaceId, "Work")
        val rootId = list.visibleRootTaskId!!
        val visibleIds = store.visibleRootTasks(workspaceId).map { it.id }
        store.deleteList(list.id)
        store.undo()
        assertEquals(rootId, store.visibleRootParentTaskId(list))
        assertEquals(visibleIds, store.visibleRootTasks(workspaceId).map { it.id })
    }

    @Test
    fun noOpReorderRenameAndMovePreserveRedoAndPosition() = fixture {
        val task = store.createTask(listId = inboxId, title = "First")
        store.updateTask(task.id, "Renamed", "", null, null)
        store.undo()
        store.moveTaskWithinSiblings(task.id, -1)
        store.moveTask(id = task.id, toListId = inboxId)
        store.renameList(inboxId, "  Inbox  ")
        store.moveList(inboxId, null)
        assertEquals("Edit Task", store.redoableLabel())
        assertEquals("Edit Task", store.redo())
        assertEquals("Renamed", store.task(task.id)?.title)
    }

    @Test
    fun renamingAListRefiledByFolderDeletionDoesNotReorderTheSidebar() = fixture {
        val folder = store.createFolder(workspaceId = workspaceId, name = "Folder")
        val list = store.createList(workspaceId = workspaceId, name = "AAA", folderId = folder.id)
        store.deleteFolder(folder.id)
        val before = store.lists(workspaceId).map { it.id }
        store.renameList(list.id, "ZZZ")
        assertEquals(before, store.lists(workspaceId).map { it.id })
        store.moveListWithinFolder(list.id, -1)
        assertEquals(listOf(list.id, inboxId), store.lists(workspaceId).map { it.id })
    }
}
