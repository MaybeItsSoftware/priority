package uk.co.maybeitsadam.takt.data.workspace

import java.time.temporal.ChronoUnit
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.core.TaskEditorMetadata
import uk.co.maybeitsadam.takt.core.TaskMatrixPosition
import uk.co.maybeitsadam.takt.core.TaskStatus
import uk.co.maybeitsadam.takt.data.TestWorkspace

/** Port of workspace-tests/WorkspaceEditingTests.swift. */
class WorkspaceEditingTest {
    private class Fixture(val w: TestWorkspace, val workspaceId: String, val inboxId: String) {
        val store get() = w.repository

        suspend fun draft(title: String = "Original"): TaskEditorDraft {
            val task = store.createTask(listId = inboxId, title = title)
            return TaskEditorDraft(store.taskEditorSnapshot(task.id))
        }
    }

    private fun fixture(test: suspend Fixture.() -> Unit): Unit = runBlocking {
        workspace().use { w ->
            val workspaceId = w.repository.bootstrapIfNeeded().id
            Fixture(w, workspaceId, w.repository.inbox(workspaceId)!!.id).test()
        }
    }

    @Test
    fun completeTaskSaveIsOneUndoStepAndPreservesPlacementAndOtherMetadata() = fixture {
        var edit = draft()
        val id = edit.baseline.taskId
        val child = store.createTask(listId = inboxId, title = "Child", parentTaskId = id)
        store.setKanbanColumn("today", id)
        store.setMatrixPosition(TaskMatrixPosition(1, 0), id)
        edit = edit.edit {
            copy(
                title = "Changed", notes = "Notes", estimateMinutes = "15", tags = " Work, work , Launch ",
                priority = 3, dailyProgress = true,
            )
        }

        val committed = store.saveTaskEditor(edit)
        assertEquals("Changed", committed.title)
        assertEquals(listOf("Work", "Launch"), committed.metadata.tags)
        assertEquals(900, store.daily(id)?.targetSeconds)
        assertEquals("Edit Task", store.undo())
        assertEquals(edit.baseline, store.taskEditorSnapshot(id))
        assertEquals(id, store.task(child.id)?.parentTaskId)
        assertEquals("today", store.kanbanColumn(id))
        assertEquals(TaskMatrixPosition(1, 0), store.matrixPosition(id))
        store.redo()
        assertEquals(committed, store.taskEditorSnapshot(id))
    }

    @Test
    fun failureAfterContentAndMetadataWritesRollsBackEverythingIncludingHistory() = fixture {
        val edit = draft().edit { copy(title = "Changed", tags = "Tag", dailyProgress = true) }
        store.updateTask(edit.baseline.taskId, "Original", "Earlier edit", null, null)
        store.undo()
        val previousLabel = store.undoableLabel()
        val previousRedo = store.redoableLabel()
        w.otherConnection {
            it.execute(
                "CREATE TRIGGER fail_daily BEFORE INSERT ON dailies " +
                    "BEGIN SELECT RAISE(ABORT, 'Injected daily failure'); END",
            )
        }
        thrown { store.saveTaskEditor(edit) }
        assertEquals(edit.baseline, store.taskEditorSnapshot(edit.baseline.taskId))
        assertEquals(previousLabel, store.undoableLabel())
        assertEquals(previousRedo, store.redoableLabel())
    }

    @Test
    fun unchangedTaskSavePreservesRedo() = fixture {
        val edit = draft()
        store.saveTaskEditor(edit.edit { copy(title = "Changed") })
        store.undo()
        val timestamp = store.task(edit.baseline.taskId)?.updatedAt
        store.saveTaskEditor(edit)
        assertEquals(timestamp, store.task(edit.baseline.taskId)?.updatedAt)
        assertEquals("Edit Task", store.redoableLabel())
        store.redo()
        assertEquals("Changed", store.task(edit.baseline.taskId)?.title)
    }

    @Test
    fun staleMetadataAndDailySnapshotsAreRejectedWithoutOverwritingTitle() = fixture {
        var edit = draft().edit { copy(title = "Draft title") }
        store.updateTaskEditorMetadata(edit.baseline.taskId, TaskEditorMetadata(tags = listOf("New tag")))
        assertEditorError(TaskEditorError.CONFLICTING_CHANGES) { store.saveTaskEditor(edit) }
        assertEquals("Original", store.task(edit.baseline.taskId)?.title)
        edit = edit.reconciled(store.taskEditorSnapshot(edit.baseline.taskId))
        store.makeDaily(taskId = edit.baseline.taskId)
        thrown { store.saveTaskEditor(edit) }
        assertEquals("Original", store.task(edit.baseline.taskId)?.title)
    }

    @Test
    fun unrelatedTitleSavePreservesExactEstimateCommaTagsAndDailySchedule() = fixture {
        var edit = draft()
        val id = edit.baseline.taskId
        store.updateTask(id, "Original", "", null, 45)
        store.updateTaskEditorMetadata(id, TaskEditorMetadata(tags = listOf("Research, design")))
        val now = w.clock.instant.truncatedTo(ChronoUnit.SECONDS)
        val daily = store.makeDaily(taskId = id, weekdays = setOf(2, 4), intervalDays = 3, targetSeconds = 600, now = now)
        val contribution = store.logContribution(dailyId = daily.id, seconds = 60, now = now)
        edit = TaskEditorDraft(store.taskEditorSnapshot(id)).edit { copy(title = "Renamed") }
        store.saveTaskEditor(edit)
        assertEquals(45, store.task(id)?.estimateSeconds)
        assertEquals(listOf("Research, design"), store.taskEditorMetadata(id).tags)
        assertEquals(daily, store.daily(id))
        assertEquals(listOf(contribution), store.contributionHistory(dailyId = daily.id, days = 1))
    }

    @Test
    fun reEnablingDailyUsesNewEstimateButKeepsScheduleIdentityAndContributions() = fixture {
        val initial = draft()
        val id = initial.baseline.taskId
        val now = w.clock.instant.truncatedTo(ChronoUnit.SECONDS)
        val daily = store.makeDaily(taskId = id, weekdays = setOf(2), intervalDays = 4, targetSeconds = 100, now = now)
        val contribution = store.logContribution(dailyId = daily.id, seconds = 30, now = now)
        store.archiveDaily(id)
        val edit = TaskEditorDraft(store.taskEditorSnapshot(id)).edit { copy(estimateMinutes = "20", dailyProgress = true) }
        store.saveTaskEditor(edit)
        val restored = store.daily(id)!!
        assertEquals(daily.id, restored.id)
        assertEquals(daily.intervalDays, restored.intervalDays)
        assertEquals(daily.intervalAnchor, restored.intervalAnchor)
        assertEquals(daily.activeWeekdaysMask, restored.activeWeekdaysMask)
        assertEquals(1200, restored.targetSeconds)
        assertEquals(listOf(contribution), store.contributionHistory(dailyId = daily.id, days = 1))
    }

    @Test
    fun invalidEstimateAndDeletedTaskNeverSaveOtherFields() = fixture {
        var edit = draft().edit { copy(title = "Changed") }
        for (estimate in listOf("oops", "-2", "1.5.1", "nan", "inf", Long.MAX_VALUE.toString())) {
            edit = edit.edit { copy(estimateMinutes = estimate) }
            assertEditorError(TaskEditorError.INVALID_ESTIMATE) { store.saveTaskEditor(edit) }
            assertEquals("Original", store.task(edit.baseline.taskId)?.title)
        }
        edit = edit.edit { copy(estimateMinutes = "1") }
        store.deleteTask(edit.baseline.taskId)
        assertStoreError(WorkspaceStoreError.MISSING_TASK) { store.saveTaskEditor(edit) }
    }

    @Test
    fun fractionalMinutesSaveAsSecondsAndTitleEditsDoNotChangeThem() = fixture {
        val edit = draft().edit { copy(estimateMinutes = "0.75") }
        val committed = store.saveTaskEditor(edit)
        assertEquals(45, committed.estimateSeconds)
        assertEquals("0.75", committed.values.estimateMinutes)
        val rename = TaskEditorDraft(committed).edit { copy(title = "Renamed") }
        assertEquals(45, store.saveTaskEditor(rename).estimateSeconds)
    }

    @Test
    fun completionAndPlacementChangesDoNotInvalidateOrGetOverwrittenByEditorSave() = fixture {
        val edit = draft().edit { copy(title = "Renamed") }
        val id = edit.baseline.taskId
        val destination = store.createList(workspaceId = workspaceId, name = "Other")
        store.moveTask(id = id, toListId = destination.id)
        store.setStatus(TaskStatus.COMPLETED, id)
        store.saveTaskEditor(edit)
        assertEquals(TaskStatus.COMPLETED, store.task(id)?.status)
        assertEquals(destination.id, store.task(id)?.listId)
        assertEquals("Renamed", store.task(id)?.title)
    }

    @Test
    fun folderRenameAndInvalidMoveAreAtomicAndPickerExcludesAllDescendants() = fixture {
        val parent = store.createFolder(workspaceId = workspaceId, name = "Parent", now = epoch(100))
        val child = store.createFolder(workspaceId = workspaceId, name = "Child", parentFolderId = parent.id)
        val grandchild = store.createFolder(workspaceId = workspaceId, name = "Grandchild", parentFolderId = child.id)
        val other = store.createFolder(workspaceId = workspaceId, name = "Other")
        assertEquals(listOf(other.id), store.validParentFolders(parent.id).map { it.id })
        for (invalid in listOf(parent.id, child.id, grandchild.id)) {
            thrown { store.saveFolderSettings(parent.id, "Renamed", invalid) }
            assertEquals(parent, store.folders(workspaceId).first { it.id == parent.id })
        }
        store.saveFolderSettings(parent.id, "Renamed", other.id)
        assertEquals("Edit Folder", store.undo())
        assertEquals(parent, store.folders(workspaceId).first { it.id == parent.id })
    }

    @Test
    fun listSettingsUndoTogetherAndForbiddenInboxArchiveRollsBackRename() = fixture {
        val folder = store.createFolder(workspaceId = workspaceId, name = "Folder")
        val list = store.createList(workspaceId = workspaceId, name = "Work", now = epoch(100))
        store.saveListSettings(list.id, "Clients", "#abcdef", folder.id, isArchived = true, visibleRootTaskId = null)
        assertEquals("Edit List", store.undo())
        assertEquals(list, store.lists(workspaceId).first { it.id == list.id })
        store.redo()
        val committed = store.lists(workspaceId, includingArchived = true).first { it.id == list.id }
        assertEquals("Clients", committed.name)
        assertEquals(folder.id, committed.folderId)
        assertTrue(committed.isArchived)
        thrown { store.saveListSettings(inboxId, "Capture", null, folder.id, isArchived = true, visibleRootTaskId = null) }
        assertEquals("Inbox", store.inbox(workspaceId)?.name)
        assertNull(store.inbox(workspaceId)?.folderId)
    }

    @Test
    fun crossWorkspaceSettingsDestinationsAreRejected() = fixture {
        val otherId = newId()
        w.otherConnection {
            it.execute(
                "INSERT INTO workspaces(id, name, createdAt, updatedAt) VALUES (?, 'Other', ?, ?)",
                otherId, w.clock.instant, w.clock.instant,
            )
        }
        val other = store.createFolder(workspaceId = otherId, name = "Other")
        val folder = store.createFolder(workspaceId = workspaceId, name = "Folder")
        thrown { store.saveFolderSettings(folder.id, "Renamed", other.id) }
        thrown { store.saveListSettings(inboxId, "Renamed", null, other.id, isArchived = false, visibleRootTaskId = null) }
        assertEquals("Inbox", store.inbox(workspaceId)?.name)
    }

    /** The Swift fixture is an `importTasks` run; [importedList] writes the same rows without registering a root. */
    @Test
    fun legacyRootRecoveryIsExplicitUndoableAndDoesNotMoveOrRenameTasks() = fixture {
        val list = w.importedList(workspaceId, name = "Clients", rootTitle = "Old work name", registerRoot = false)
        assertNull(store.visibleRootParentTaskId(list))
        val root = store.visibleRootCandidates(list.id).first()
        val before = store.outline(list.id)
        store.saveListSettings(list.id, list.name, null, null, isArchived = false, visibleRootTaskId = root.id)
        assertEquals(root.id, store.visibleRootParentTaskId(list))
        assertEquals(before, store.outline(list.id))
        w.reopened { reopened ->
            assertEquals(root.id, reopened.visibleRootParentTaskId(list))
            reopened.undo()
            assertNull(reopened.visibleRootParentTaskId(list))
            reopened.redo()
            assertEquals(root.id, reopened.visibleRootParentTaskId(list))
        }
    }

    @Test
    fun invalidVisibleRootChoiceDoesNotApplyOtherListEdits() = fixture {
        val edit = draft()
        assertEditorError(TaskEditorError.INVALID_VISIBLE_ROOT) {
            store.saveListSettings(inboxId, "Capture", null, null, isArchived = false, visibleRootTaskId = edit.baseline.taskId)
        }
        assertEquals("Inbox", store.inbox(workspaceId)?.name)
    }
}
