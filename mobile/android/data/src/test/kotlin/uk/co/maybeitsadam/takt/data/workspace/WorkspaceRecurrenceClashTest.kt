package uk.co.maybeitsadam.takt.data.workspace

import java.time.Instant
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.core.TaskEditorMetadata
import uk.co.maybeitsadam.takt.data.TestWorkspace

/** The repository's side of a repeating task moved onto its next turn; the rule itself is the core's. */
class WorkspaceRecurrenceClashTest {
    // Ahead of the clock: the next turn is the first one after now as well as
    // after the task's date, so an overdue task brought to today is no clash.
    private val monday9: Instant = Instant.parse("2099-10-05T09:00:00Z")
    private val day = 86_400L

    private class Fixture(val w: TestWorkspace, val inboxId: String) {
        val store get() = w.repository
    }

    private fun fixture(test: suspend Fixture.() -> Unit): Unit = runBlocking {
        workspace().use { w ->
            val workspaceId = w.repository.bootstrapIfNeeded().id
            Fixture(w, w.repository.inbox(workspaceId)!!.id).test()
        }
    }

    private suspend fun Fixture.daily(): String {
        val task = store.createTask(listId = inboxId, title = "Stretch", dueAt = monday9)
        store.updateTaskEditorMetadata(task.id, TaskEditorMetadata(recurrenceRule = "daily"))
        return task.id
    }

    @Test
    fun movingTheDueOntoTheNextTurnIsAClashAndWithinTheDayIsNot() = fixture {
        val id = daily()
        val draft = TaskEditorDraft(store.taskEditorSnapshot(id))

        val clash = store.recurrenceClash(draft.edit { copy(dueAt = monday9.plusSeconds(day)) })
        assertNotNull(clash)
        assertEquals(id, clash!!.taskId)
        assertEquals(monday9.plusSeconds(day), clash.movedTo)
        assertNull(store.recurrenceClash(draft.edit { copy(dueAt = monday9.plusSeconds(3_600)) }))
        assertNull(store.recurrenceClash(id, monday9.plusSeconds(3_600), null))
        assertNotNull(store.recurrenceClash(id, monday9.plusSeconds(2 * day), null))
    }

    @Test
    fun aTaskThatDoesNotRepeatNeverClashes() = fixture {
        val task = store.createTask(listId = inboxId, title = "Once", dueAt = monday9)
        assertNull(store.recurrenceClash(task.id, monday9.plusSeconds(7 * day), null))
    }

    @Test
    fun scheduleOnlyCountsWhenTheStartIsAllTheTaskHas() = fixture {
        val dueOnly = daily()
        assertNull(store.startClash(dueOnly, monday9.plusSeconds(day)))

        val startOnly = store.createTask(listId = inboxId, title = "Read", startAt = monday9).id
        store.updateTaskEditorMetadata(startOnly, TaskEditorMetadata(recurrenceRule = "daily"))
        assertNotNull(store.startClash(startOnly, monday9.plusSeconds(day)))
    }

    @Test
    fun keepBothCopiesTheMovedTaskAsAOneOffInTheMovesStep() = fixture {
        val id = daily()
        val moved = monday9.plusSeconds(day)
        store.saveTaskEditor(TaskEditorDraft(store.taskEditorSnapshot(id)).edit { copy(dueAt = moved) })

        val copy = store.addOccurrenceCopy(id)

        assertEquals("Keep Both", store.undoableLabel())
        val copied = store.taskEditorSnapshot(copy)
        assertEquals("Stretch", copied.title)
        assertEquals(moved, copied.dueAt)
        assertNull(copied.metadata.recurrenceRule)
        assertEquals("daily", store.taskEditorSnapshot(id).metadata.recurrenceRule)
        // One undo takes back the copy and the move it answered.
        store.undo()
        assertFalse(store.tasks(inboxId).any { it.id == copy })
        assertTrue(store.tasks(inboxId).any { it.id == id })
        assertEquals(monday9, store.taskEditorSnapshot(id).dueAt)
    }

    @Test
    fun aWriteWaitsOutTheMoveAndItsCopyWrittenTogether() = fixture {
        val id = daily()
        val other = store.createTask(listId = inboxId, title = "Other").id
        val moved = monday9.plusSeconds(day)
        val inBetween = CompletableDeferred<Unit>()
        coroutineScope {
            var landing: Deferred<Unit>? = null
            store.writingTogether {
                store.saveTaskEditor(TaskEditorDraft(store.taskEditorSnapshot(id)).edit { copy(dueAt = moved) })
                // A write from elsewhere, between the move and the copy: it waits.
                landing = this@coroutineScope.async(Dispatchers.Default) {
                    inBetween.complete(Unit)
                    store.updateTask(other, "Renamed", "", null, null)
                }
                inBetween.await()
                store.addOccurrenceCopy(id)
            }
            landing!!.await()
        }

        assertEquals("Renamed", store.task(other)?.title)
        store.undo()
        assertEquals("Other", store.task(other)?.title)
        // The next undo is the move and its copy, together.
        assertEquals("Keep Both", store.undoableLabel())
        store.undo()
        assertEquals(monday9, store.taskEditorSnapshot(id).dueAt)
    }

    @Test
    fun onlyStackAndKeepBothSaveAndOnlyKeepBothCopies() {
        assertEquals(listOf(true, true, false), RecurrenceClashChoice.entries.map { it.saves })
        assertEquals(listOf(false, true, false), RecurrenceClashChoice.entries.map { it.addsCopy })
        assertEquals(listOf("Stack on that day", "Keep both", "Cancel"), RecurrenceClashChoice.entries.map { it.title })
    }
}
