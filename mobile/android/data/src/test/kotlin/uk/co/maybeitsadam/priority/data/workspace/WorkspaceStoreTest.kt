package uk.co.maybeitsadam.priority.data.workspace

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.priority.core.PeriodicSchedule
import uk.co.maybeitsadam.priority.core.TaskEditorMetadata
import uk.co.maybeitsadam.priority.core.TaskListRole
import uk.co.maybeitsadam.priority.core.TaskMatrixPosition
import uk.co.maybeitsadam.priority.core.TaskStatus
import uk.co.maybeitsadam.priority.core.FocusQueueState

/** Port of workspace-tests/WorkspaceStoreTests.swift (the import cases are not ported). */
class WorkspaceStoreTest {

    @Test
    fun bootstrapCreatesOneWorkspaceAndInbox(): Unit = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded()
            assertEquals(listOf(workspace.id), store.workspaces().map { it.id })
            assertEquals(listOf("Inbox"), store.lists(workspace.id).map { it.name })
            assertEquals(workspace.id, store.bootstrapIfNeeded().id)
        }
    }

    @Test
    fun completionTimeIsStampedOnceAndClearedOnReopening(): Unit = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded()
            val inbox = store.lists(workspace.id).first()
            val task = store.createTask(listId = inbox.id, title = "Write it up")
            val monday = epoch(1_758_542_400)
            val tuesday = monday.plusSeconds(86_400)

            store.setStatus(TaskStatus.COMPLETED, task.id, now = monday)
            assertEquals(monday, store.task(task.id)?.completedAt)
            store.setStatus(TaskStatus.COMPLETED, task.id, now = tuesday)
            assertEquals(monday, store.task(task.id)?.completedAt)
            store.setStatus(TaskStatus.OPEN, task.id, now = tuesday)
            assertNull(store.task(task.id)?.completedAt)
        }
    }

    @Test
    fun workProgressSeparatesTodayFromTheWeekAndIgnoresLists(): Unit = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded()
            val inbox = store.lists(workspace.id).first()
            // Wednesday 2025-09-24, mid-afternoon. The week starts on Monday (firstWeekday = 2).
            val now = epoch(1_758_726_000)
            val yesterday = now.minusSeconds(86_400)
            val today = store.createTask(listId = inbox.id, title = "Today's task")
            val earlier = store.createTask(listId = inbox.id, title = "Monday's task")
            store.setStatus(TaskStatus.COMPLETED, today.id, now = now)
            store.setStatus(TaskStatus.COMPLETED, earlier.id, now = yesterday)
            val project = store.createList(workspaceId = workspace.id, name = "Project")
            store.setListCompleted(true, project.id, now = now)

            val progress = store.workProgress(now = now, zone = UTC, firstWeekday = 2)
            assertEquals(1, progress.today.completed)
            assertEquals(2, progress.week.completed)
            assertEquals(3, progress.elapsedDays)
        }
    }

    @Test
    fun completingAPeriodicTaskSchedulesTheNextOccurrence(): Unit = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded()
            val inbox = store.lists(workspace.id).first()
            val wednesday = epoch(1_758_704_400)
            val task = store.createTask(
                listId = inbox.id, title = "Water the plants", kanbanColumn = "today", startAt = wednesday,
            )
            store.updateTaskEditorMetadata(task.id, TaskEditorMetadata(recurrenceRule = "every 3 days"))

            store.setStatus(TaskStatus.COMPLETED, task.id, now = wednesday)

            val finished = store.task(task.id)!!
            assertEquals(TaskStatus.COMPLETED, finished.status)
            assertEquals(wednesday, finished.completedAt)
            val repeated = store.tasks(inbox.id).first { it.id != task.id && it.title == "Water the plants" }
            assertEquals(TaskStatus.OPEN, repeated.status)
            assertNull(repeated.completedAt)
            assertEquals(wednesday.plusSeconds(3 * 86_400), store.startAt(repeated.id))
            assertEquals(PeriodicSchedule.Cadence.Days(3), store.periodicSchedule(repeated.id)?.cadence)
            assertNull(store.kanbanColumn(repeated.id))
        }
    }

    @Test
    fun aTaskWithoutARuleIsSimplyCompleted(): Unit = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded()
            val inbox = store.lists(workspace.id).first()
            val task = store.createTask(listId = inbox.id, title = "One-off")
            store.setStatus(TaskStatus.COMPLETED, task.id)
            assertEquals(listOf(task.id), store.tasks(inbox.id).map { it.id })
        }
    }

    @Test
    fun outlineKeepsHierarchyAndCompletingATaskPersists(): Unit = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded()
            val list = store.lists(workspace.id).first()
            val root = store.createTask(listId = list.id, title = "Project")
            val child = store.createTask(listId = list.id, title = "First step", parentTaskId = root.id)
            val outline = store.outline(list.id)
            assertEquals(listOf("Project", "First step"), outline.map { it.task.title })
            assertEquals(listOf(0, 1), outline.map { it.depth })
            store.setStatus(TaskStatus.COMPLETED, child.id)
            assertEquals(TaskStatus.COMPLETED, store.task(child.id)?.status)
        }
    }

    @Test
    fun projectBoardKeepsChildColumnsIndependentOfTheirParent(): Unit = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded()
            val list = store.lists(workspace.id).first()
            val project = store.createTask(listId = list.id, title = "Prepare big document")
            val section = store.createTask(listId = list.id, title = "Section 1", parentTaskId = project.id)
            store.setKanbanColumn("in-progress", project.id)
            store.setKanbanColumn("today", section.id)
            assertEquals(listOf(project.id), store.tasks(list.id).map { it.id })
            assertEquals(listOf(section.id), store.tasks(list.id, project.id).map { it.id })
            assertEquals("in-progress", store.kanbanColumn(project.id))
            assertEquals("today", store.kanbanColumn(section.id))
        }
    }

    @Test
    fun matrixPositionIsLocalMetadataAndDoesNotChangeTaskHierarchy(): Unit = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded()
            val list = store.lists(workspace.id).first()
            val task = store.createTask(listId = list.id, title = "Plan launch")
            store.setMatrixPosition(TaskMatrixPosition(1, 1), task.id)
            assertEquals(TaskMatrixPosition(1, 1), store.matrixPosition(task.id))
            assertEquals(listOf(task.id), store.tasks(list.id).map { it.id })
        }
    }

    @Test
    fun focusSessionCompletesCurrentTaskAndAdvancesQueue(): Unit = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded()
            val list = store.lists(workspace.id).first()
            val first = store.createTask(listId = list.id, title = "Write")
            val second = store.createTask(listId = list.id, title = "Review")
            val session = store.startFocusSession(taskId = first.id)
            store.addToFocusQueue(session.id, second.id)

            val advanced = store.completeActiveFocusTask(sessionId = session.id)

            assertEquals(TaskStatus.COMPLETED, store.task(first.id)?.status)
            assertEquals(FocusCompletionOutcome.TaskCompleted, advanced.outcome)
            assertEquals(second.id, advanced.session.activeTaskId)
            assertEquals(
                listOf(FocusQueueState.COMPLETED, FocusQueueState.QUEUED),
                store.focusQueue(session.id).map { it.item.state },
            )
        }
    }

    @Test
    fun advancingTheQueueRestartsTheBlockClock(): Unit = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded()
            val list = store.lists(workspace.id).first()
            val first = store.createTask(listId = list.id, title = "Write")
            val second = store.createTask(listId = list.id, title = "Review")
            val start = epoch(1_700_000_000)
            val session = store.startFocusSession(taskId = first.id, now = start)
            store.addToFocusQueue(session.id, second.id, now = start)
            assertEquals(start, session.activeTaskStartedAt)

            val handover = start.plusSeconds(30 * 60)
            val advanced = store.completeActiveFocusTask(sessionId = session.id, now = handover)
            assertEquals(start, advanced.session.startedAt)
            assertEquals(handover, advanced.session.activeTaskStartedAt)
        }
    }

    @Test
    fun renamingAListKeepsItsColourAndIsUndoableOnItsOwn(): Unit = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded()
            val list = store.createList(workspaceId = workspace.id, name = "Wrk")
            store.updateList(list.id, "Wrk", "#7a4de8")
            store.renameList(list.id, "  Work  ")
            val renamed = store.lists(workspace.id).first { it.id == list.id }
            assertEquals("Work", renamed.name)
            assertEquals("#7a4de8", renamed.colorHex)
            assertEquals("Rename List", store.undoableLabel())
            assertEquals("Rename List", store.undo())
            assertEquals("Wrk", store.lists(workspace.id).first { it.id == list.id }.name)
        }
    }

    @Test
    fun renamingRefusesAnEmptyNameAndRenamingTheInboxIsAllowed(): Unit = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded()
            val inbox = store.inbox(workspace.id)!!
            assertStoreError(WorkspaceStoreError.EMPTY_NAME) { store.renameList(inbox.id, "   ") }
            store.renameList(inbox.id, "Capture")
            assertEquals("Capture", store.inbox(workspace.id)?.name)
        }
    }

    @Test
    fun moveTaskMovesEntireSubtreeAndRejectsCircularParent(): Unit = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded()
            val inbox = store.lists(workspace.id).first()
            val destination = store.createList(workspaceId = workspace.id, name = "Project")
            val parent = store.createTask(listId = inbox.id, title = "Parent")
            val child = store.createTask(listId = inbox.id, title = "Child", parentTaskId = parent.id)
            val grandchild = store.createTask(listId = inbox.id, title = "Grandchild", parentTaskId = child.id)

            assertStoreError(WorkspaceStoreError.INVALID_TASK_MOVE) {
                store.moveTask(id = parent.id, toListId = inbox.id, parentTaskId = grandchild.id)
            }
            store.moveTask(id = parent.id, toListId = destination.id)

            assertEquals(listOf("Parent", "Child", "Grandchild"), store.outline(destination.id).map { it.task.title })
            assertEquals(destination.id, store.task(child.id)?.listId)
            assertEquals(destination.id, store.task(grandchild.id)?.listId)
            assertTrue(store.outline(inbox.id).isEmpty())
        }
    }

    @Test
    fun indentOutdentAndSiblingOrderingPreserveOutline(): Unit = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded()
            val list = store.lists(workspace.id).first()
            store.createTask(listId = list.id, title = "First")
            val second = store.createTask(listId = list.id, title = "Second")
            val third = store.createTask(listId = list.id, title = "Third")

            store.moveTaskWithinSiblings(third.id, -2)
            assertEquals(listOf("Third", "First", "Second"), store.outline(list.id).map { it.task.title })
            store.indentTask(second.id)
            assertEquals(listOf("Third", "First", "Second"), store.outline(list.id).map { it.task.title })
            assertEquals(listOf(0, 0, 1), store.outline(list.id).map { it.depth })
            store.outdentTask(second.id)
            assertEquals(listOf(0, 0, 0), store.outline(list.id).map { it.depth })
        }
    }

    @Test
    fun boardCaptureAtTopAndCardDropOrderRemainProjectScoped(): Unit = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded()
            val list = store.lists(workspace.id).first()
            val first = store.createTask(listId = list.id, title = "First")
            val second = store.createTask(listId = list.id, title = "Second")
            val top = store.createTask(listId = list.id, title = "New Today task")
            store.moveTaskToStart(top.id)
            assertEquals(listOf(top.id, first.id, second.id), store.tasks(list.id).map { it.id })

            store.moveTaskBefore(second.id, first.id)
            assertEquals(listOf(top.id, second.id, first.id), store.tasks(list.id).map { it.id })

            val child = store.createTask(listId = list.id, title = "Child", parentTaskId = first.id)
            assertStoreError(WorkspaceStoreError.INVALID_TASK_MOVE) { store.moveTaskBefore(child.id, top.id) }
            assertEquals(first.id, store.task(child.id)?.parentTaskId)
        }
    }

    @Test
    fun folderAndListMovesAreScopedAndDeletingFolderKeepsLists(): Unit = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded()
            val top = store.createFolder(workspaceId = workspace.id, name = "Work")
            val nested = store.createFolder(workspaceId = workspace.id, name = "Client", parentFolderId = top.id)
            val list = store.createList(workspaceId = workspace.id, name = "Launch", folderId = nested.id)

            assertStoreError(WorkspaceStoreError.INVALID_FOLDER_MOVE) { store.moveFolder(top.id, nested.id) }
            store.moveList(list.id, top.id)
            assertEquals(top.id, store.lists(workspace.id).first { it.id == list.id }.folderId)
            store.deleteFolder(top.id)
            assertNull(store.lists(workspace.id).first { it.id == list.id }.folderId)
        }
    }

    @Test
    fun listsAndFoldersCanBeReorderedWithinTheirSiblings(): Unit = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded()
            val firstFolder = store.createFolder(workspaceId = workspace.id, name = "First")
            val secondFolder = store.createFolder(workspaceId = workspace.id, name = "Second")
            store.moveFolderWithinSiblings(secondFolder.id, -1)
            assertEquals(listOf("Second", "First"), store.folders(workspace.id).map { it.name })

            val project = store.createList(workspaceId = workspace.id, name = "Project")
            val someday = store.createList(workspaceId = workspace.id, name = "Someday")
            store.moveListWithinFolder(someday.id, -2)
            assertEquals(
                listOf("Someday", "Inbox", "Project"),
                store.lists(workspace.id).filter { it.folderId == null }.map { it.name },
            )
            store.moveList(project.id, firstFolder.id)
            store.moveListWithinFolder(project.id, -1)
            assertEquals(firstFolder.id, store.lists(workspace.id).first { it.id == project.id }.folderId)
        }
    }

    @Test
    fun droppingAListPlacesItWhereItLandedAcrossFolders(): Unit = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded()
            val folder = store.createFolder(workspaceId = workspace.id, name = "Work")
            val project = store.createList(workspaceId = workspace.id, name = "Project")
            val someday = store.createList(workspaceId = workspace.id, name = "Someday")
            val inbox = store.lists(workspace.id).first { it.systemRole == TaskListRole.INBOX }
            suspend fun topLevel() = store.lists(workspace.id).filter { it.folderId == null }.map { it.name }

            store.placeList(someday.id, inbox.id, null)
            assertEquals(listOf("Someday", "Inbox", "Project"), topLevel())
            store.placeList(someday.id, null, null)
            assertEquals(listOf("Inbox", "Project", "Someday"), topLevel())
            store.placeList(project.id, null, folder.id)
            assertEquals(folder.id, store.lists(workspace.id).first { it.id == project.id }.folderId)
            assertEquals(listOf("Inbox", "Someday"), topLevel())
        }
    }

    @Test
    fun droppingAFolderPlacesItAndRefusesItsOwnDescendant(): Unit = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded()
            val first = store.createFolder(workspaceId = workspace.id, name = "First")
            val second = store.createFolder(workspaceId = workspace.id, name = "Second")
            val child = store.createFolder(workspaceId = workspace.id, name = "Child", parentFolderId = first.id)

            store.placeFolder(second.id, first.id, null)
            assertEquals(
                listOf("Second", "First"),
                store.folders(workspace.id).filter { it.parentFolderId == null }.map { it.name },
            )
            assertStoreError(WorkspaceStoreError.INVALID_FOLDER_MOVE) { store.placeFolder(first.id, null, child.id) }
            assertNull(store.folders(workspace.id).first { it.id == first.id }.parentFolderId)
        }
    }

    @Test
    fun taskEditorMetadataNormalizesAndPersistsInspectorFields(): Unit = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded()
            val list = store.lists(workspace.id).first()
            val task = store.createTask(listId = list.id, title = "Plan launch")
            store.updateTaskEditorMetadata(
                task.id,
                TaskEditorMetadata(
                    priority = 3,
                    tags = listOf("Work", " work ", "Launch", ""),
                    recurrenceRule = " every Monday ",
                    externalLinks = listOf("https://example.com/spec", "https://example.com/spec", " "),
                ),
            )
            assertEquals(
                TaskEditorMetadata(
                    priority = 3, tags = listOf("Work", "Launch"), recurrenceRule = "every Monday",
                    externalLinks = listOf("https://example.com/spec"),
                ),
                store.taskEditorMetadata(task.id),
            )
        }
    }

    /** Swift seeds its 1,200 tasks through `importTasks`; here they are written directly. */
    @Test
    fun batchedBoardMetadataMatchesIndividualReadsAcrossBatchBoundaries(): Unit = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded()
            val list = store.createList(workspaceId = workspace.id, name = "Large board")
            val ids = (0 until 1200).map { "TASK-$it" }
            w.database.write { db ->
                ids.forEachIndexed { index, id ->
                    db.execute(
                        "INSERT INTO tasks (id, listId, title, status, sortOrder, createdAt, updatedAt) " +
                            "VALUES (?, ?, ?, 'open', ?, ?, ?)",
                        id, list.id, "Task $index", index, w.clock.instant, w.clock.instant,
                    )
                    if (index % 3 != 0) {
                        db.execute(
                            "INSERT INTO task_metadata(taskId, tagsJSON, externalLinksJSON, matrixUrgency, " +
                                "matrixImportance, kanbanColumn, updatedAt) VALUES (?, '[]', '[]', ?, ?, ?, ?)",
                            id, index % 100, (index * 7) % 100, if (index % 2 == 0) "today" else null, w.clock.instant,
                        )
                    }
                }
            }
            val expectedColumns = mutableMapOf<String, String>()
            val expectedPositions = mutableMapOf<String, TaskMatrixPosition>()
            for (id in ids) {
                store.kanbanColumn(id)?.let { expectedColumns[id] = it }
                expectedPositions[id] = store.matrixPosition(id)
            }
            val metadata = store.boardMetadata(ids + ids[0])
            assertEquals(expectedColumns, metadata.columns)
            assertEquals(expectedPositions, metadata.positions)

            val empty = store.boardMetadata(emptyList())
            assertTrue(empty.columns.isEmpty())
            assertTrue(empty.positions.isEmpty())
            store.setKanbanColumn("later", ids[0])
            assertEquals("later", store.boardMetadata(listOf(ids[0])).columns[ids[0]])
            store.undo()
            assertNull(store.boardMetadata(listOf(ids[0])).columns[ids[0]])
        }
    }

    @Test
    fun bulkColumnMovePreservesMetadataAndIsOneAtomicUndoStep(): Unit = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded()
            val list = store.inbox(workspace.id)!!
            val first = store.createTask(listId = list.id, title = "First")
            val second = store.createTask(listId = list.id, title = "Second")
            val position = TaskMatrixPosition(25, 80)
            store.setMatrixPosition(position, first.id)
            store.setKanbanColumn("today", first.id)
            store.setKanbanColumn("later", listOf(first.id, second.id, first.id))
            assertEquals("later", store.kanbanColumn(first.id))
            assertEquals("later", store.kanbanColumn(second.id))
            assertEquals(position, store.matrixPosition(first.id))
            store.undo()
            assertEquals("today", store.kanbanColumn(first.id))
            assertNull(store.kanbanColumn(second.id))
            store.redo()
            assertEquals("later", store.kanbanColumn(second.id))
            assertNotNull(thrown { store.setKanbanColumn("done", listOf(first.id, "missing")) })
            assertEquals("later", store.kanbanColumn(first.id))
            assertEquals(position, store.matrixPosition(first.id))
        }
    }
}
