package uk.co.maybeitsadam.takt.data.workspace

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.data.TestWorkspace

/**
 * Port of workspace-tests/TaskEditorDraftTests.swift. The three cases about
 * `TaskEditorDraftStore` (drafts persisted to a JSON file) are not ported: the
 * file store is not part of the Android data layer.
 */
class TaskEditorDraftTest {
    private fun withInitial(test: suspend (TestWorkspace, TaskEditorSnapshot) -> Unit): Unit = runBlocking {
        workspace().use { w ->
            val workspace = w.repository.bootstrapIfNeeded()
            val task = w.repository.createTask(listId = w.repository.inbox(workspace.id)!!.id, title = "Original")
            test(w, w.repository.taskEditorSnapshot(task.id))
        }
    }

    @Test
    fun cleanDraftRefreshesAllFieldsIncludingMetadataAndDailyState() = withInitial { _, initial ->
        val saved = initial.copy(
            title = "Restored by undo",
            metadata = initial.metadata.copy(tags = listOf("Tag")),
            dailyProgress = true,
        )
        val draft = TaskEditorDraft(initial).reconciled(saved)
        assertEquals(saved.values, draft.values)
        assertFalse(draft.isDirty)
    }

    @Test
    fun dirtyNotesSurviveUnrelatedSavedTitleChange() = withInitial { _, initial ->
        val saved = initial.copy(title = "Restored by undo")
        val draft = TaskEditorDraft(initial).edit { copy(notes = "My notes") }.reconciled(saved)
        assertEquals("My notes", draft.values.notes)
        assertEquals(saved.title, draft.values.title)
        assertTrue(draft.conflicts.isEmpty())
        assertEquals(saved.title, draft.validatedSnapshot().title)
    }

    @Test
    fun conflictsPersistAcrossRefreshUntilExplicitlyResolvedAndSubsequentChangesConflictAgain() = withInitial { _, initial ->
        var saved = initial.copy(title = "Saved edit")
        var draft = TaskEditorDraft(initial).edit { copy(title = "My edit") }.reconciled(saved).reconciled(saved)
        assertEquals("My edit", draft.values.title)
        assertEquals(setOf(TaskEditorField.TITLE), draft.conflicts)
        thrown { draft.validatedSnapshot() }
        draft = draft.resolved(TaskEditorField.TITLE, useSaved = false)
        assertEquals("My edit", draft.validatedSnapshot().title)
        saved = saved.copy(title = "Another saved edit")
        draft = draft.reconciled(saved)
        assertEquals(setOf(TaskEditorField.TITLE), draft.conflicts)
        draft = draft.resolved(TaskEditorField.TITLE, useSaved = true)
        assertEquals(saved.title, draft.values.title)
        assertFalse(draft.isDirty)
    }

    @Test
    fun convergingValuesBecomeCleanWithoutAConflict() = withInitial { _, initial ->
        val draft = TaskEditorDraft(initial).edit { copy(title = "Same edit") }.reconciled(initial.copy(title = "Same edit"))
        assertFalse(draft.isDirty)
        assertTrue(draft.conflicts.isEmpty())
    }

    @Test
    fun exactEstimateChangesConflictWithDirtyMinutesButConvergingEstimateDoesNot() = withInitial { _, initial ->
        var snapshot = initial.copy(estimateSeconds = 45)
        var draft = TaskEditorDraft(snapshot).edit { copy(estimateMinutes = "1") }
        snapshot = snapshot.copy(estimateSeconds = 59)
        draft = draft.reconciled(snapshot)
        assertEquals(setOf(TaskEditorField.ESTIMATE_MINUTES), draft.conflicts)
        snapshot = snapshot.copy(estimateSeconds = 60)
        draft = draft.reconciled(snapshot)
        assertTrue(draft.conflicts.isEmpty())
        assertFalse(draft.isDirty)
    }

    @Test
    fun deletingAndRestoringTaskPreservesItsDraftButPreventsSavingWhileMissing() = withInitial { _, initial ->
        var draft = TaskEditorDraft(initial).edit { copy(notes = "Retain these") }.copy(isUnavailable = true)
        thrown { draft.validatedSnapshot() }
        draft = draft.reconciled(initial)
        assertFalse(draft.isUnavailable)
        assertEquals("Retain these", draft.validatedSnapshot().notes)
    }

    /** The store half of the fractional-due-date case, without the JSON round trip. */
    @Test
    fun aFractionalDueDateDoesNotMakeASavedDraftFalselyStale() = withInitial { w, initial ->
        val store = w.repository
        store.updateTask(initial.taskId, initial.title, "", java.time.Instant.ofEpochMilli(123_456_789), null)
        val snapshot = store.taskEditorSnapshot(initial.taskId)
        val draft = TaskEditorDraft(snapshot).edit { copy(title = "Renamed") }
        assertEquals(snapshot, draft.baseline)
        assertEquals("Renamed", store.saveTaskEditor(draft).title)
    }
}
