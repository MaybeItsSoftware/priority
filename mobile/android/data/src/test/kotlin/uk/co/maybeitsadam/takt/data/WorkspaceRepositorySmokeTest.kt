package uk.co.maybeitsadam.takt.data

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.core.TaskStatus

class WorkspaceRepositorySmokeTest {
    @Test
    fun bootstrapCreateUndoRedo(): Unit = runBlocking {
        TestWorkspace().use { w ->
            val repo = w.repository
            val workspace = repo.bootstrapIfNeeded()
            val inbox = repo.inbox(workspace.id)!!
            assertEquals("Inbox", inbox.name)
            assertEquals(4, repo.conditions(workspace.id).size)
            assertNull(repo.undoableLabel())

            val task = repo.createTask(listId = inbox.id, title = "  Buy milk  ")
            assertEquals("Buy milk", task.title)
            assertTrue(task.id == task.id.uppercase())
            assertEquals("New Task", repo.undoableLabel())

            repo.setStatus(TaskStatus.COMPLETED, task.id)
            assertEquals(TaskStatus.COMPLETED, repo.task(task.id)!!.status)
            assertEquals("Change Status", repo.undo())
            assertEquals(TaskStatus.OPEN, repo.task(task.id)!!.status)
            assertEquals("Change Status", repo.redoableLabel())
            assertEquals("Change Status", repo.redo())
            assertEquals(TaskStatus.COMPLETED, repo.task(task.id)!!.status)

            repo.undo(); repo.undo()
            assertNull(repo.task(task.id))
            repo.redo()
            assertEquals("Buy milk", repo.task(task.id)!!.title)
        }
    }

    @Test
    fun dateTextMatchesGrdb(): Unit = runBlocking {
        TestWorkspace().use { w ->
            val workspace = w.repository.bootstrapIfNeeded()
            val text = w.database.read { it.string("SELECT createdAt FROM workspaces WHERE id = ?", workspace.id) }
            assertEquals("2026-10-02 09:00:00.000", text)
        }
    }

    @Test
    fun captureSyntaxIsReadOffTheTitle(): Unit = runBlocking {
        TestWorkspace().use { w ->
            val workspace = w.repository.bootstrapIfNeeded()
            val inbox = w.repository.inbox(workspace.id)!!
            val task = w.repository.createTask(capturing = "Write report 45m #work !1", listId = inbox.id)
            assertEquals("Write report", task.title)
            assertEquals(45 * 60, task.estimateSeconds)
            assertEquals(listOf("work"), w.repository.taskEditorMetadata(task.id).tags)
            assertEquals(1, w.repository.taskEditorMetadata(task.id).priority)
        }
    }

    @Test
    fun flowsRequeryAfterWrites(): Unit = runBlocking {
        TestWorkspace().use { w ->
            val workspace = w.repository.bootstrapIfNeeded()
            val inbox = w.repository.inbox(workspace.id)!!
            val seen = mutableListOf<Int>()
            val job = launch {
                w.repository.observeTaskCounts().take(2).toList().forEach { seen += it.open }
            }
            w.repository.observeTaskCounts().first()
            w.repository.createTask(listId = inbox.id, title = "One")
            job.join()
            assertEquals(listOf(0, 1), seen)
        }
    }

    @Test
    fun searchFindsPrefixesThroughFts5(): Unit = runBlocking {
        TestWorkspace().use { w ->
            val workspace = w.repository.bootstrapIfNeeded()
            val inbox = w.repository.inbox(workspace.id)!!
            w.repository.createTask(listId = inbox.id, title = "Invoice the client")
            w.repository.createTask(listId = inbox.id, title = "Meetings")
            assertEquals(listOf("Invoice the client"), w.repository.searchTasks(workspace.id, "inv").map { it.task.title })
            assertEquals(listOf("Meetings"), w.repository.searchTasks(workspace.id, "meeting").map { it.task.title })
            assertTrue(w.repository.searchTasks(workspace.id, "!!!").isEmpty())
        }
    }
}
