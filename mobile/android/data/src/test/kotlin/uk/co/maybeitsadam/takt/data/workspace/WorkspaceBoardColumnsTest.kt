package uk.co.maybeitsadam.takt.data.workspace

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import uk.co.maybeitsadam.takt.core.TaskList
import uk.co.maybeitsadam.takt.core.WorkspaceKanbanColumn
import uk.co.maybeitsadam.takt.data.TestWorkspace
import uniffi.takt_core.FilterDefinition
import uniffi.takt_core.FilterRule

/** Board columns through the repository: the Rust core's `board_columns`, as the phone reaches it. */
class WorkspaceBoardColumnsTest {
    private class Fixture(val w: TestWorkspace, val work: TaskList, val home: TaskList) {
        val store get() = w.repository
        val workKey get() = "${work.id}/root"
        val homeKey get() = "${home.id}/root"
    }

    private fun fixture(test: suspend Fixture.() -> Unit): Unit = runBlocking {
        workspace().use { w ->
            val ws = w.repository.bootstrapIfNeeded()
            Fixture(w, w.repository.createList(ws.id, "Work"), w.repository.createList(ws.id, "Home")).test()
        }
    }

    private val urgent = WorkspaceKanbanColumn(
        "urgent", "Urgent", FilterDefinition("all", "all", listOf(FilterRule("tag", "has", "urgent"))),
    )

    @Test
    fun aListWithoutItsOwnLayoutFollowsTheDefault() = fixture {
        assertEquals("builtin", store.boardColumns(homeKey, listOf(home.id)).source)
        val custom = listOf(WorkspaceKanbanColumn("now", "Now"), WorkspaceKanbanColumn("later", "Later"))
        store.setKanbanBoardColumns(custom, workKey)
        assertEquals("own", store.boardColumns(workKey, listOf(work.id)).source)

        store.makeDefaultBoardColumns(workKey)
        assertEquals("Make Default Columns", store.undoableLabel())
        val followed = store.boardColumns(homeKey, listOf(home.id))
        assertEquals("default", followed.source)
        assertEquals(custom, followed.layout)
        // The board it came from follows the default from then on too.
        assertEquals("default", store.boardColumns(workKey, listOf(work.id)).source)

        store.resetBoardColumns(DEFAULT_KEY)
        assertEquals("builtin", store.boardColumns(homeKey, listOf(home.id)).source)
    }

    @Test
    fun deletingAColumnMovesItsTasksInOneUndoStep() = fixture {
        val layout = WorkspaceKanbanColumn.blitzitDefaults + WorkspaceKanbanColumn("extra", "Extra")
        store.setKanbanBoardColumns(layout, workKey)
        val card = store.createTask(listId = work.id, title = "Filed", kanbanColumn = "extra")

        store.deleteBoardColumn(workKey, listOf(work.id), "extra", "backlog")
        assertEquals("backlog", store.kanbanColumn(card.id))
        assertFalse(store.boardColumns(workKey, listOf(work.id)).layout.any { it.id == "extra" })

        assertEquals("Delete Column", store.undo())
        assertEquals("extra", store.kanbanColumn(card.id))
        assertEquals(layout, store.boardColumns(workKey, listOf(work.id)).layout)
    }

    @Test
    fun aRuleColumnPlacesTheTasksItMatchesAndADropEditsATaskToMatch() = fixture {
        store.setKanbanBoardColumns(listOf(urgent) + WorkspaceKanbanColumn.blitzitDefaults, workKey)
        val tagged = store.createTask(listId = work.id, title = "Tagged", kanbanColumn = "today", tags = listOf("urgent"))
        val plain = store.createTask(listId = work.id, title = "Plain", kanbanColumn = "today")

        val read = store.boardColumns(workKey, listOf(work.id))
        assertTrue(read.layout.first().isRuleColumn)
        assertEquals(urgent.rules, read.layout.first().rules)
        assertEquals("urgent", read.placements[tagged.id])
        assertNull(read.placements[plain.id])
        assertEquals("urgent", read.columnId(tagged.id, "today"))
        assertEquals("today", read.columnId(plain.id, "today"))

        store.moveToBoardColumn(workKey, listOf(plain.id), "urgent")
        assertEquals("Move Task", store.undoableLabel())
        assertEquals("urgent", store.boardColumns(workKey, listOf(work.id)).placements[plain.id])
        // Filed where it was: the rule column holds it by its tag.
        assertEquals("today", store.kanbanColumn(plain.id))
    }

    @Test
    fun aDropARuleColumnCannotMeetIsRefusedWithTheCoresReason() = fixture {
        val mentions = WorkspaceKanbanColumn(
            "calls", "Calls", FilterDefinition("all", "all", listOf(FilterRule("text", "contains", "call"))),
        )
        store.setKanbanBoardColumns(listOf(mentions) + WorkspaceKanbanColumn.blitzitDefaults, workKey)
        val task = store.createTask(listId = work.id, title = "Write", kanbanColumn = "today")
        try {
            store.moveToBoardColumn(workKey, listOf(task.id), "calls")
            fail("The core should refuse a drop it cannot make true")
        } catch (refused: WorkspaceStoreException) {
            assertEquals(WorkspaceStoreError.COLUMN_REFUSED, refused.error)
            assertNotNull(refused.detail)
            assertTrue(refused.text.contains("Calls"))
        }
        assertEquals("today", store.kanbanColumn(task.id))
    }

    @Test
    fun editingTheLayoutKeepsARuleColumnsRules() = fixture {
        store.setKanbanBoardColumns(listOf(urgent) + WorkspaceKanbanColumn.blitzitDefaults, workKey)
        val layout = store.boardColumns(workKey, listOf(work.id)).layout
        store.setKanbanBoardColumns(layout + WorkspaceKanbanColumn("new", "New"), workKey, label = "Add Board Column")
        val saved = store.boardColumns(workKey, listOf(work.id)).layout
        assertEquals(urgent, saved.first())
        assertEquals("new", saved.last().id)
        assertEquals(urgent, store.observeKanbanBoards().first()[workKey]?.first())
    }

    private companion object {
        const val DEFAULT_KEY = "default"
    }
}
