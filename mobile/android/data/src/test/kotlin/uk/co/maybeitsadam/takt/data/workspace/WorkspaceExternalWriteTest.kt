package uk.co.maybeitsadam.takt.data.workspace

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test
import uk.co.maybeitsadam.takt.core.TaskStatus
import uk.co.maybeitsadam.takt.data.TestWorkspace

/**
 * Port of workspace-tests/WorkspaceExternalWriteTests.swift. Kotlin has one
 * (suspend) token reader, so the Swift test that compares the awaited and
 * synchronous readers checks the same three readings against that one.
 */
class WorkspaceExternalWriteTest {
    private fun fixture(test: suspend (TestWorkspace, String) -> Unit): Unit = runBlocking {
        workspace().use { w ->
            val workspace = w.repository.bootstrapIfNeeded()
            test(w, w.repository.inbox(workspace.id)!!.id)
        }
    }

    @Test
    fun theTokenIgnoresTheStoresOwnWrites() = fixture { w, listId ->
        val store = w.repository
        val before = store.externalChangeToken()
        store.createTask(listId = listId, title = "Mine")
        store.setStatus(TaskStatus.COMPLETED, store.tasks(listId).first().id)
        assertEquals(before, store.externalChangeToken())
    }

    @Test
    fun theTokenMovesWhenAnotherConnectionCommits() = fixture { w, listId ->
        val store = w.repository
        val before = store.externalChangeToken()
        w.otherConnection { it.execute("UPDATE task_lists SET name = 'Elsewhere' WHERE id = ?", listId) }
        assertNotEquals(before, store.externalChangeToken())
        assertEquals("Elsewhere", store.lists(store.workspaces().first().id).first { it.id == listId }.name)
    }

    @Test
    fun theTokenStaysForOwnWritesAndMovesForOthersInOneSequence() = fixture { w, listId ->
        val store = w.repository
        val before = store.externalChangeToken()
        store.createTask(listId = listId, title = "Mine")
        assertEquals(before, store.externalChangeToken())
        w.otherConnection { it.execute("UPDATE task_lists SET name = 'Elsewhere' WHERE id = ?", listId) }
        assertNotEquals(before, store.externalChangeToken())
    }

    /** The statements cli/src/workspace_tasks.rs runs for `workspace_task_add` with a link. */
    @Test
    fun aWriteJournalledTheWayTheCLIDoesIsOneUndoStep() = fixture { w, listId ->
        val store = w.repository
        val taskId = newId()
        val now = "2026-09-27 10:00:00.000"
        w.otherConnection { db ->
            db.execute("BEGIN IMMEDIATE")
            db.execute(
                "UPDATE undo_control SET groupId = ?, label = 'MCP: New Task', suppressed = 0 WHERE id = 0", newId(),
            )
            db.execute(
                "INSERT INTO tasks (id, listId, parentTaskId, title, notes, status, sortOrder, createdAt, updatedAt, itemKind) " +
                    "VALUES (?, ?, NULL, 'From the assistant', 'Some notes', 'open', 0, ?, ?, 'task')",
                taskId, listId, now, now,
            )
            db.execute(
                "INSERT INTO task_metadata (taskId, tagsJSON, externalLinksJSON, updatedAt) " +
                    "VALUES (?, '[]', '[\"obsidian://open?vault=Studies&file=Paper\"]', ?)",
                taskId, now,
            )
            db.execute("UPDATE undo_control SET suppressed = 1 WHERE id = 0")
            db.execute("COMMIT")
        }

        val task = store.task(taskId)!!
        assertEquals("From the assistant", task.title)
        assertEquals(1_790_503_200_000L, task.createdAt.toEpochMilli())
        assertEquals(listOf("obsidian://open?vault=Studies&file=Paper"), store.taskEditorMetadata(taskId).externalLinks)
        val workspaceId = store.workspaces().first().id
        assertEquals(listOf(taskId), store.searchTasks(workspaceId, "assistant").map { it.task.id })

        assertEquals("MCP: New Task", store.undoableLabel())
        assertEquals("MCP: New Task", store.undo())
        assertNull(store.task(taskId))
        assertEquals("MCP: New Task", store.redo())
        assertEquals(1, store.taskEditorMetadata(taskId).externalLinks.size)
    }
}
