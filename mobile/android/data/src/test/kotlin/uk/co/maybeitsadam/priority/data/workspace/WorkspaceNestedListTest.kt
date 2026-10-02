package uk.co.maybeitsadam.priority.data.workspace

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.priority.core.TaskList
import uk.co.maybeitsadam.priority.core.TaskStatus
import uk.co.maybeitsadam.priority.core.WorkspaceItemKind
import uk.co.maybeitsadam.priority.data.TestWorkspace

/**
 * Port of workspace-tests/WorkspaceNestedListTests.swift. Imported lists are
 * written by [importedList] rather than `importTasks`.
 */
class WorkspaceNestedListTest {
    private class Fixture(val w: TestWorkspace, val workspaceId: String, val list: TaskList) {
        val store get() = w.repository
    }

    private fun fixture(test: suspend Fixture.() -> Unit): Unit = runBlocking {
        workspace().use { w ->
            val workspaceId = w.repository.bootstrapIfNeeded().id
            Fixture(w, workspaceId, w.repository.createList(workspaceId = workspaceId, name = "Committees 2026–27")).test()
        }
    }

    @Test
    fun conversionPreservesIdentityHierarchyAndTaskDetailsAndIsUndoable() = fixture {
        val task = store.createTask(listId = list.id, title = "Sailing")
        val child = store.createTask(listId = list.id, title = "Book boats", parentTaskId = task.id)
        val due = epoch(1_900_000_000)
        store.updateTask(task.id, task.title, "Notes", due, 600)
        store.setItemKind(WorkspaceItemKind.LIST, task.id)
        val converted = store.task(task.id)!!
        assertTrue(converted.isList)
        assertEquals("Notes", converted.notes)
        assertEquals(due, converted.dueAt)
        assertEquals(600, converted.estimateSeconds)
        assertEquals(task.id, store.task(child.id)?.parentTaskId)
        assertEquals("Convert to List", store.undo())
        assertFalse(store.task(task.id)!!.isList)
        store.redo()
        assertTrue(store.task(task.id)!!.isList)
    }

    @Test
    fun promotionIsPersistedWithoutMovingTheNestedList() = fixture {
        val parent = store.createTask(listId = list.id, title = "Societies", kind = WorkspaceItemKind.LIST)
        val nested = store.createTask(listId = list.id, title = "Sailing", parentTaskId = parent.id, kind = WorkspaceItemKind.LIST)
        store.setNestedListPromoted(true, nested.id)
        w.reopened { reopened ->
            val saved = reopened.task(nested.id)!!
            assertEquals(true, saved.isPromoted)
            assertEquals(parent.id, saved.parentTaskId)
            assertEquals(list.id, saved.listId)
            reopened.undo()
            assertNotEquals(true, reopened.task(nested.id)?.isPromoted)
        }
    }

    @Test
    fun everythingAndFocusExcludeContainersButIncludeNestedTasks() = fixture {
        val parent = store.createTask(listId = list.id, title = "Sailing", kind = WorkspaceItemKind.LIST)
        val empty = store.createTask(listId = list.id, title = "Ideas", kind = WorkspaceItemKind.LIST)
        val child = store.createTask(listId = list.id, title = "Book boats", parentTaskId = parent.id)
        assertEquals(listOf(child.id), store.actionableTasks(workspaceId).map { it.id })
        assertEquals(listOf(child.id), store.nextUpCandidates().map { it.id })
        thrown { store.startFocusSession(taskId = empty.id) }
    }

    @Test
    fun completingAContainerSuppressesItsDescendantsWithoutCompletingThem() = fixture {
        val parent = store.createTask(listId = list.id, title = "Sailing", kind = WorkspaceItemKind.LIST)
        val nested = store.createTask(listId = list.id, title = "Trip", parentTaskId = parent.id, kind = WorkspaceItemKind.LIST)
        val child = store.createTask(listId = list.id, title = "Book boats", parentTaskId = nested.id)
        store.setStatus(TaskStatus.COMPLETED, parent.id)
        assertTrue(store.actionableTasks(workspaceId).isEmpty())
        assertTrue(store.nextUpCandidates().isEmpty())
        assertEquals(TaskStatus.OPEN, store.task(child.id)?.status)
        thrown { store.startFocusSession(taskId = child.id) }
        store.undo()
        assertEquals(listOf(child.id), store.actionableTasks(workspaceId).map { it.id })
    }

    @Test
    fun archivingNestedListCanBeRestoredAndUndone() = fixture {
        val parent = store.createTask(listId = list.id, title = "Sailing", kind = WorkspaceItemKind.LIST)
        val child = store.createTask(listId = list.id, title = "Book boats", parentTaskId = parent.id)
        store.setNestedListArchived(true, parent.id)
        assertTrue(store.actionableTasks(workspaceId).isEmpty())
        assertTrue(store.nextUpCandidates().isEmpty())
        store.setNestedListArchived(false, parent.id)
        assertEquals(listOf(child.id), store.actionableTasks(workspaceId).map { it.id })
        store.undo()
        assertNotNull(store.task(parent.id)?.archivedAt)
    }

    @Test
    fun topLevelListCanEndAndReopenWithoutLosingTasks() = fixture {
        val task = store.createTask(listId = list.id, title = "Annual handover")
        store.setListCompleted(true, list.id)
        assertNotNull(store.lists(workspaceId).first { it.id == list.id }.completedAt)
        assertTrue(store.actionableTasks(workspaceId).isEmpty())
        assertTrue(store.nextUpCandidates().isEmpty())
        assertEquals(TaskStatus.OPEN, store.task(task.id)?.status)
        store.setListCompleted(false, list.id)
        assertEquals(listOf(task.id), store.actionableTasks(workspaceId).map { it.id })
        val inbox = store.inbox(workspaceId)!!
        thrown { store.setListCompleted(true, inbox.id) }
    }

    @Test
    fun convertingBackToTaskClearsListOnlyFlagsAndRetainsChildren() = fixture {
        val parent = store.createTask(listId = list.id, title = "Trip", kind = WorkspaceItemKind.LIST)
        val child = store.createTask(listId = list.id, title = "Hotel", parentTaskId = parent.id)
        store.setNestedListPromoted(true, parent.id)
        store.setNestedListArchived(true, parent.id)
        store.setItemKind(WorkspaceItemKind.TASK, parent.id)
        val saved = store.task(parent.id)!!
        assertFalse(saved.isList)
        assertNull(saved.isPromoted)
        assertNull(saved.archivedAt)
        assertEquals(parent.id, store.task(child.id)?.parentTaskId)
    }

    @Test
    fun tasksWithChildrenAreNotAutomaticallyLists() = fixture {
        val parent = store.createTask(listId = list.id, title = "Pack bag")
        store.createTask(listId = list.id, title = "Find passport", parentTaskId = parent.id)
        assertFalse(store.task(parent.id)!!.isList)
        thrown { store.setNestedListPromoted(true, parent.id) }
    }

    @Test
    fun standaloneListConvertsToAnInboxTaskAndUndoRestoresTheList() = fixture {
        val task = store.createTask(listId = list.id, title = "Sailing", kind = WorkspaceItemKind.LIST)
        val child = store.createTask(listId = list.id, title = "Boats", parentTaskId = task.id)
        store.setNestedListPromoted(true, task.id)
        val root = store.convertListToTask(list.id)
        val inbox = store.inbox(workspaceId)!!
        assertEquals(inbox.id, root.listId)
        assertFalse(root.isList)
        assertEquals(list.name, root.title)
        assertEquals(root.id, store.task(task.id)?.parentTaskId)
        assertEquals(task.id, store.task(child.id)?.parentTaskId)
        assertEquals(inbox.id, store.task(child.id)?.listId)
        assertEquals(true, store.task(task.id)?.isPromoted)
        assertFalse(store.lists(workspaceId).any { it.id == list.id })
        store.undo()
        assertTrue(store.lists(workspaceId).any { it.id == list.id })
        assertEquals(list.id, store.task(child.id)?.listId)
        assertNull(store.task(root.id))
        store.redo()
        assertEquals(inbox.id, store.task(child.id)?.listId)
    }

    @Test
    fun standaloneConversionReusesAnImportedWrapperAndPreservesMetadata() = fixture {
        val imported = w.importedList(workspaceId, "Study", childTitle = "Read")
        val wrapperId = imported.visibleRootTaskId!!
        store.updateTask(wrapperId, "Study", "Keep these notes", null, 600)
        store.setKanbanColumn("today", wrapperId)
        val root = store.convertListToTask(imported.id)
        assertEquals(wrapperId, root.id)
        assertEquals("Keep these notes", root.notes)
        assertEquals("root", root.sourceId)
        assertEquals("today", store.kanbanColumn(wrapperId))
        assertEquals(1, store.tasks(root.listId, root.id).size)
        store.undo()
        assertEquals(wrapperId, store.visibleRootParentTaskId(imported))
    }

    @Test
    fun archivedContainersAndTheirDescendantsAreHiddenFromVisibleOutline() = fixture {
        val parent = store.createTask(listId = list.id, title = "Old year", kind = WorkspaceItemKind.LIST)
        store.createTask(listId = list.id, title = "Archived work", parentTaskId = parent.id)
        val sibling = store.createTask(listId = list.id, title = "New year", kind = WorkspaceItemKind.LIST)
        store.setNestedListArchived(true, parent.id)
        assertEquals(listOf(sibling.id), store.visibleOutline(list.id).map { it.id })
        assertEquals(3, store.outline(list.id).size)
    }

    @Test
    fun movingAPromotedListKeepsThePromotionAndCannotCreateACycle() = fixture {
        val parent = store.createTask(listId = list.id, title = "Societies", kind = WorkspaceItemKind.LIST)
        val nested = store.createTask(listId = list.id, title = "Sailing", parentTaskId = parent.id, kind = WorkspaceItemKind.LIST)
        store.setNestedListPromoted(true, nested.id)
        thrown { store.moveTask(id = parent.id, toListId = list.id, parentTaskId = nested.id) }
        val destination = store.createList(workspaceId = workspaceId, name = "Next year")
        store.moveTask(id = nested.id, toListId = destination.id)
        assertEquals(true, store.task(nested.id)?.isPromoted)
        assertEquals(destination.id, store.task(nested.id)?.listId)
        store.undo()
        assertEquals(parent.id, store.task(nested.id)?.parentTaskId)
    }

    @Test
    fun convertingTheCurrentFocusTaskIntoAContainerIsRejected() = fixture {
        val task = store.createTask(listId = list.id, title = "Current work")
        store.startFocusSession(taskId = task.id)
        thrown { store.setItemKind(WorkspaceItemKind.LIST, task.id) }
        assertFalse(store.task(task.id)!!.isList)
    }

    @Test
    fun standaloneListCanBeDroppedIntoAnotherListAsOneUndoableSubtree() = fixture {
        val parent = store.createList(workspaceId = workspaceId, name = "University")
        val task = store.createTask(listId = list.id, title = "Sailing", kind = WorkspaceItemKind.LIST)
        val child = store.createTask(listId = list.id, title = "Boats", parentTaskId = task.id)
        val nested = store.nestList(id = list.id, inListId = parent.id)
        assertTrue(nested.isList)
        assertEquals(list.name, nested.title)
        assertNull(nested.parentTaskId)
        assertEquals(nested.id, store.task(task.id)?.parentTaskId)
        assertEquals(task.id, store.task(child.id)?.parentTaskId)
        assertEquals(parent.id, store.task(child.id)?.listId)
        assertFalse(store.lists(workspaceId).any { it.id == list.id })
        assertEquals("Move List into List", store.undo())
        assertEquals(list.id, store.task(child.id)?.listId)
        assertNull(store.task(nested.id))
        store.redo()
        assertEquals(parent.id, store.task(child.id)?.listId)
    }

    @Test
    fun standaloneListCanBeDroppedIntoANestedListAndSelfDropsAreRejected() = fixture {
        val parent = store.createList(workspaceId = workspaceId, name = "University")
        val nested = store.createTask(listId = parent.id, title = "Societies", kind = WorkspaceItemKind.LIST)
        val root = store.nestList(id = list.id, inListId = parent.id, parentTaskId = nested.id)
        assertEquals(nested.id, root.parentTaskId)
        thrown { store.nestList(id = parent.id, inListId = parent.id, parentTaskId = root.id) }
        val inbox = store.inbox(workspaceId)!!
        thrown { store.nestList(id = inbox.id, inListId = parent.id) }
    }

    @Test
    fun importedStandaloneListReusesWrapperAndDropsBesideDestinationVisibleRoots() = fixture {
        val source = w.importedList(workspaceId, "Study", childTitle = "Read", rootSourceId = "sourceRoot", childSourceId = "sourceChild")
        val destination = w.importedList(workspaceId, "University", childTitle = "Admin", rootSourceId = "destRoot", childSourceId = "destChild")
        val nested = store.nestList(id = source.id, inListId = destination.id)
        assertEquals(source.visibleRootTaskId, nested.id)
        assertEquals(destination.visibleRootTaskId, nested.parentTaskId)
        assertTrue(nested.isList)
        assertEquals(2, store.tasks(destination.id, destination.visibleRootTaskId).size)
        store.undo()
        assertEquals(source.visibleRootTaskId, store.visibleRootParentTaskId(source))
    }

    @Test
    fun taskCanMoveBetweenNestedListsWithinTheSameStandaloneList() = fixture {
        val source = store.createTask(listId = list.id, title = "Sailing", kind = WorkspaceItemKind.LIST)
        val destination = store.createTask(listId = list.id, title = "Hiking", kind = WorkspaceItemKind.LIST)
        val task = store.createTask(listId = list.id, title = "Book transport", parentTaskId = source.id)
        val child = store.createTask(listId = list.id, title = "Get quote", parentTaskId = task.id)
        store.moveTask(id = task.id, toListId = list.id, parentTaskId = destination.id)
        assertEquals(destination.id, store.task(task.id)?.parentTaskId)
        assertEquals(task.id, store.task(child.id)?.parentTaskId)
        store.undo()
        assertEquals(source.id, store.task(task.id)?.parentTaskId)
    }

    @Test
    fun nestedListCanBecomeATopLevelListAndUndoRestoresItsParent() = fixture {
        val parent = store.createTask(listId = list.id, title = "Societies", kind = WorkspaceItemKind.LIST)
        val nested = store.createTask(listId = list.id, title = "Sailing", parentTaskId = parent.id, kind = WorkspaceItemKind.LIST)
        val child = store.createTask(listId = list.id, title = "Boats", parentTaskId = nested.id)
        val standalone = store.moveTaskToFolder(nested.id, null)
        assertNull(standalone.folderId)
        assertEquals(nested.id, standalone.visibleRootTaskId)
        assertEquals(nested.title, standalone.name)
        assertNull(store.task(nested.id)?.parentTaskId)
        assertEquals(standalone.id, store.task(child.id)?.listId)
        assertEquals(nested.id, store.task(child.id)?.parentTaskId)
        assertEquals(listOf(child.id), store.visibleRootTasks(workspaceId).filter { it.listId == standalone.id }.map { it.id })
        assertEquals("Move Item to Top Level", store.undo())
        assertEquals(parent.id, store.task(nested.id)?.parentTaskId)
        assertEquals(list.id, store.task(child.id)?.listId)
        store.redo()
        assertEquals(standalone.id, store.task(child.id)?.listId)
    }

    @Test
    fun nestedListCanBeMovedIntoAFolderWithoutLosingItsContents() = fixture {
        val folder = store.createFolder(workspaceId = workspaceId, name = "University")
        val parent = store.createTask(listId = list.id, title = "Societies", kind = WorkspaceItemKind.LIST)
        val nested = store.createTask(listId = list.id, title = "Sailing", parentTaskId = parent.id, kind = WorkspaceItemKind.LIST)
        val child = store.createTask(listId = list.id, title = "Boats", parentTaskId = nested.id)
        store.setNestedListPromoted(true, nested.id)
        val standalone = store.moveTaskToFolder(nested.id, folder.id)
        assertEquals(folder.id, standalone.folderId)
        assertEquals(nested.title, standalone.name)
        assertEquals(nested.id, standalone.visibleRootTaskId)
        assertNull(store.task(nested.id)?.parentTaskId)
        assertEquals(nested.id, store.task(child.id)?.parentTaskId)
        assertEquals(standalone.id, store.task(child.id)?.listId)
        assertEquals(listOf(child.id), store.visibleRootTasks(workspaceId).filter { it.listId == standalone.id }.map { it.id })
        store.undo()
        assertEquals(parent.id, store.task(nested.id)?.parentTaskId)
        assertEquals(true, store.task(nested.id)?.isPromoted)
        assertEquals(list.id, store.task(child.id)?.listId)
        store.redo()
        assertEquals(standalone.id, store.task(child.id)?.listId)
    }

    @Test
    fun tasksDroppedOnAFolderBecomeSeparateTopLevelLists() = fixture {
        val folder = store.createFolder(workspaceId = workspaceId, name = "University")
        val task = store.createTask(listId = list.id, title = "Book boats")
        val child = store.createTask(listId = list.id, title = "Get a quote", parentTaskId = task.id)
        val other = store.createTask(listId = list.id, title = "Book room")
        val first = store.moveTaskToFolder(task.id, folder.id)
        val second = store.moveTaskToFolder(other.id, folder.id)
        assertNotEquals(first.id, second.id)
        assertEquals("Book boats", first.name)
        assertEquals("Book room", second.name)
        assertEquals(task.id, first.visibleRootTaskId)
        assertEquals(other.id, second.visibleRootTaskId)
        assertEquals(folder.id, first.folderId)
        assertTrue(store.task(task.id)!!.isList)
        assertNull(store.task(task.id)?.parentTaskId)
        assertEquals(listOf(child.id), store.visibleOutline(first.id, first.visibleRootTaskId).map { it.task.id })
        assertEquals(task.id, store.task(child.id)?.parentTaskId)
        assertEquals(first.id, store.task(child.id)?.listId)
        store.undo()
        assertEquals(list.id, store.task(other.id)?.listId)
        assertFalse(store.task(other.id)!!.isList)
        store.undo()
        assertEquals(list.id, store.task(child.id)?.listId)
        assertFalse(store.task(task.id)!!.isList)
        assertFalse(store.lists(workspaceId).any { it.id == first.id })
    }

    @Test
    fun standaloneListCanMoveToAFolderWithoutChangingIdentity() = fixture {
        val folder = store.createFolder(workspaceId = workspaceId, name = "University")
        val task = store.createTask(listId = list.id, title = "Handover")
        store.moveList(list.id, folder.id)
        assertEquals(folder.id, store.lists(workspaceId).first { it.id == list.id }.folderId)
        assertEquals(list.id, store.task(task.id)?.listId)
        store.undo()
        assertNull(store.lists(workspaceId).first { it.id == list.id }.folderId)
    }

    @Test
    fun folderMoveRejectsAnotherWorkspaceAndKeepsClosedContainerState() = fixture {
        val elsewhereId = newId()
        w.otherConnection {
            it.execute(
                "INSERT INTO workspaces (id, name, createdAt, updatedAt) VALUES (?, ?, ?, ?)",
                elsewhereId, "Elsewhere", w.clock.instant, w.clock.instant,
            )
        }
        val otherFolder = store.createFolder(workspaceId = elsewhereId, name = "Other")
        val nested = store.createTask(listId = list.id, title = "Last year", kind = WorkspaceItemKind.LIST)
        val child = store.createTask(listId = list.id, title = "Handover", parentTaskId = nested.id)
        thrown { store.moveTaskToFolder(nested.id, otherFolder.id) }
        assertEquals(list.id, store.task(child.id)?.listId)
        val folder = store.createFolder(workspaceId = workspaceId, name = "University")
        store.setStatus(TaskStatus.COMPLETED, nested.id)
        val standalone = store.moveTaskToFolder(nested.id, folder.id)
        assertNotNull(standalone.completedAt)
        assertFalse(store.actionableTasks(workspaceId).any { it.id == child.id })
        assertEquals(TaskStatus.OPEN, store.task(child.id)?.status)
    }

    @Test
    fun emptyNestedListMovedToFolderHasAValidVisibleRootAndEditableSettings() = fixture {
        val folder = store.createFolder(workspaceId = workspaceId, name = "University")
        val nested = store.createTask(listId = list.id, title = "Sailing", kind = WorkspaceItemKind.LIST)
        val standalone = store.moveTaskToFolder(nested.id, folder.id)
        assertEquals(listOf(nested.id), store.visibleRootCandidates(standalone.id).map { it.id })
        store.saveListSettings(standalone.id, "Sailing", null, folder.id, isArchived = false, visibleRootTaskId = null)
        store.saveListSettings(standalone.id, "Sailing plans", "#abcdef", folder.id, isArchived = false, visibleRootTaskId = nested.id)
        assertEquals(nested.id, store.visibleRootParentTaskId(standalone))
        assertTrue(store.tasks(standalone.id, nested.id).isEmpty())
    }
}
