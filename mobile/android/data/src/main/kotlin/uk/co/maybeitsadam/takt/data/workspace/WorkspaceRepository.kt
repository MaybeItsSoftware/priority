package uk.co.maybeitsadam.takt.data.workspace

import java.time.Clock
import java.time.Instant
import java.time.ZoneId
import kotlinx.coroutines.flow.Flow
import uk.co.maybeitsadam.takt.core.DailyContribution
import uk.co.maybeitsadam.takt.core.DailyItem
import uk.co.maybeitsadam.takt.core.DayBoundary
import uk.co.maybeitsadam.takt.core.FocusAward
import uk.co.maybeitsadam.takt.core.FocusContext
import uk.co.maybeitsadam.takt.core.FocusPointsSummary
import uk.co.maybeitsadam.takt.core.FocusQueueItem
import uk.co.maybeitsadam.takt.core.FocusQueueState
import uk.co.maybeitsadam.takt.core.FocusQueueTask
import uk.co.maybeitsadam.takt.core.FocusSession
import uk.co.maybeitsadam.takt.core.FocusSessionPhase
import uk.co.maybeitsadam.takt.core.FocusWorkBlock
import uk.co.maybeitsadam.takt.core.NextUpCandidate
import uk.co.maybeitsadam.takt.core.NextUpSelector
import uk.co.maybeitsadam.takt.core.PeriodicSchedule
import uk.co.maybeitsadam.takt.core.StaleFocusPolicy
import uk.co.maybeitsadam.takt.core.StaleFocusResolution
import uk.co.maybeitsadam.takt.core.TaskAvailabilityPolicy
import uk.co.maybeitsadam.takt.core.TaskCapture
import uk.co.maybeitsadam.takt.core.TaskCondition
import uk.co.maybeitsadam.takt.core.TaskPlanning
import uk.co.maybeitsadam.takt.core.TaskPlanningError
import uk.co.maybeitsadam.takt.core.WorkProgress
import uk.co.maybeitsadam.takt.core.WorkspaceDaily
import uk.co.maybeitsadam.takt.core.WorkspaceNextUpSnapshot
import uk.co.maybeitsadam.takt.core.secondsBetween
import uk.co.maybeitsadam.takt.core.defaultFirstWeekday
import uk.co.maybeitsadam.takt.core.ListFolder
import uk.co.maybeitsadam.takt.core.TaskEditorMetadata
import uk.co.maybeitsadam.takt.core.TaskList
import uk.co.maybeitsadam.takt.core.TaskMatrixPosition
import uk.co.maybeitsadam.takt.core.TaskMetadata
import uk.co.maybeitsadam.takt.core.TaskOutlineItem
import uk.co.maybeitsadam.takt.core.TaskStatus
import uk.co.maybeitsadam.takt.core.Workspace
import uk.co.maybeitsadam.takt.core.WorkspaceItemKind
import uk.co.maybeitsadam.takt.core.WorkspaceKanbanColumn
import uk.co.maybeitsadam.takt.core.WorkspaceListTree
import uk.co.maybeitsadam.takt.core.WorkspaceTask
import uk.co.maybeitsadam.takt.data.db.Db
import uk.co.maybeitsadam.takt.data.db.SqlDates
import uk.co.maybeitsadam.takt.data.db.WorkspaceDatabase
import uk.co.maybeitsadam.takt.data.db.WorkspaceSchema

/**
 * The local source of truth for the workspace: a port of the Swift
 * `WorkspaceStore` and its extensions onto the same SQLite schema.
 *
 * Every method is a suspend function on the database's dispatcher. Writes that
 * touch the user's work go through [journalledWrite], so each is one undo
 * step, exactly as on the Mac. Reads have `observe…` flow variants that re-query
 * when a relevant table changes, which is what a ViewModel collects.
 *
 * `now` defaults to [clock] truncated to milliseconds (what GRDB stores), and
 * day arithmetic uses [zone], the Swift `Calendar.current`'s time zone.
 */
class WorkspaceRepository(
    val database: WorkspaceDatabase,
    private val clock: Clock = Clock.systemUTC(),
    private val zoneProvider: () -> ZoneId = { ZoneId.systemDefault() },
) {
    internal fun now(): Instant = SqlDates.truncate(clock.instant())
    internal val zone: ZoneId get() = zoneProvider()

    // region Journal (WorkspaceStore+Undo.swift)

    /**
     * Runs a mutation as one undoable step: recording is switched on for the
     * transaction, a real change invalidates redo, and the journal is trimmed
     * to [JOURNAL_DEPTH] whole groups.
     */
    internal suspend fun <T> journalledWrite(label: String, block: (Db) -> T): T = database.write { db ->
        val groupId = newId()
        db.execute(
            "UPDATE undo_control SET groupId = ?, label = ?, suppressed = 0 WHERE id = 0",
            groupId, label,
        )
        try {
            val result = block(db)
            db.execute("UPDATE undo_control SET suppressed = 1 WHERE id = 0")
            // A key pressed at the end of a list can be a no-op. Only an actual
            // change creates a new history branch and invalidates redo.
            if (db.exists("SELECT 1 FROM change_log WHERE groupId = ?", groupId)) {
                db.execute("DELETE FROM change_log WHERE undone = 1")
            }
            trimJournal(db)
            result
        } finally {
            runCatching { db.execute("UPDATE undo_control SET suppressed = 1 WHERE id = 0") }
        }
    }

    /** What undo would take back, phrased for a menu item; nil when there is nothing. */
    suspend fun undoableLabel(): String? = database.coreRead { it.undoableLabel() }

    suspend fun redoableLabel(): String? = database.coreRead { it.redoableLabel() }

    /** Both labels, re-read whenever the journal changes. */
    fun observeHistoryLabels(): Flow<Pair<String?, String?>> = database.observe(setOf("change_log")) {
        it.string("SELECT label FROM change_log WHERE undone = 0 ORDER BY id DESC LIMIT 1") to
            it.string("SELECT label FROM change_log WHERE undone = 1 ORDER BY id ASC LIMIT 1")
    }

    /** The task and list the next undo (or redo) affects, so the UI can reveal restored work. */
    suspend fun historyTarget(forUndo: Boolean): HistoryTarget =
        database.coreRead { it.historyTarget(forUndo) }.let { HistoryTarget(it.taskId, it.listId) }

    /**
     * Reverses the most recent group of changes. Returns its label, or nil when there was nothing to undo.
     * The replay is the Rust core's (core/src/journal.rs), the same code the Mac and the CLI's steps use.
     */
    suspend fun undo(): String? = database.coreWrite(REPLAYED_TABLES) { it.undo() }

    suspend fun redo(): String? = database.coreWrite(REPLAYED_TABLES) { it.redo() }

    /** The journal, newest first, for a history pane. */
    suspend fun history(limit: Int = 100): List<HistoryEntry> =
        database.coreRead { it.undoHistory(limit.coerceAtLeast(0).toUInt()) }.map {
            HistoryEntry(it.id, it.label, it.isUndone, it.changeCount.toInt())
        }

    private fun trimJournal(db: Db) {
        db.execute(
            "DELETE FROM change_log WHERE groupId IN (" +
                "SELECT groupId FROM change_log GROUP BY groupId " +
                "ORDER BY MAX(id) DESC LIMIT -1 OFFSET $JOURNAL_DEPTH)",
        )
    }

    // endregion

    // region Workspaces, folders and lists (WorkspaceStore.swift)

    /** The workspace, created with its Inbox and default conditions on first launch. */
    suspend fun bootstrapIfNeeded(now: Instant = now()): Workspace {
        val existing = database.read { db ->
            db.queryOne("SELECT * FROM workspaces LIMIT 1") { it.toWorkspace() }
        }
        if (existing != null) {
            database.write { db -> ensureInbox(db, existing.id, now) }
            return existing
        }
        val workspace = Workspace(newId(), "My Workspace", now, now)
        database.write { db ->
            db.insert(workspace)
            ensureInbox(db, workspace.id, now)
            seedConditions(db, workspace.id, now)
        }
        return workspace
    }

    /** The list quick capture lands in, found by its role rather than its name. */
    suspend fun inbox(workspaceId: String): TaskList? = database.read { inbox(it, workspaceId) }

    suspend fun workspaces(): List<Workspace> = database.read { db ->
        db.query("SELECT * FROM workspaces ORDER BY createdAt") { it.toWorkspace() }
    }

    fun observeWorkspaces(): Flow<List<Workspace>> = database.observe(setOf("workspaces")) { db ->
        db.query("SELECT * FROM workspaces ORDER BY createdAt") { it.toWorkspace() }
    }

    suspend fun folders(workspaceId: String): List<ListFolder> = database.read { foldersIn(it, workspaceId) }

    fun observeFolders(workspaceId: String): Flow<List<ListFolder>> =
        database.observe(setOf("list_folders")) { foldersIn(it, workspaceId) }

    suspend fun lists(workspaceId: String, includingArchived: Boolean = false): List<TaskList> =
        database.read { listsIn(it, workspaceId, includingArchived) }

    fun observeLists(workspaceId: String, includingArchived: Boolean = false): Flow<List<TaskList>> =
        database.observe(setOf("task_lists")) { listsIn(it, workspaceId, includingArchived) }

    suspend fun createFolder(
        workspaceId: String,
        name: String,
        parentFolderId: String? = null,
        now: Instant = now(),
    ): ListFolder {
        val trimmed = nonEmptyName(name)
        return journalledWrite("New Folder") { db ->
            if (parentFolderId != null) {
                val folder = db.folder(parentFolderId)
                if (folder == null || folder.workspaceId != workspaceId) fail(WorkspaceStoreError.MISSING_FOLDER)
            }
            val order = db.nextOrder("list_folders", "workspaceId = ? AND parentFolderId IS ?", workspaceId, parentFolderId)
            ListFolder(newId(), workspaceId, parentFolderId, trimmed, order, now, now).also { db.insert(it) }
        }
    }

    suspend fun createList(
        workspaceId: String,
        name: String,
        folderId: String? = null,
        now: Instant = now(),
    ): TaskList {
        val trimmed = nonEmptyName(name)
        return journalledWrite("New List") { db ->
            if (folderId != null) {
                val folder = db.folder(folderId)
                if (folder == null || folder.workspaceId != workspaceId) fail(WorkspaceStoreError.MISSING_FOLDER)
            }
            val order = db.nextOrder("task_lists", "workspaceId = ? AND folderId IS ?", workspaceId, folderId)
            TaskList(
                id = newId(), workspaceId = workspaceId, folderId = folderId, name = trimmed, colorHex = null,
                sortOrder = order, isArchived = false, systemRole = null, visibleRootTaskId = null,
                completedAt = null, createdAt = now, updatedAt = now,
            ).also { db.insert(it) }
        }
    }

    suspend fun task(id: String): WorkspaceTask? = database.read { it.task(id) }

    fun observeTask(id: String): Flow<WorkspaceTask?> = database.observe(setOf("tasks")) { it.task(id) }

    suspend fun updateFolder(id: String, name: String, now: Instant = now()) {
        val trimmed = nonEmptyName(name)
        journalledWrite("Rename Folder") { db ->
            val folder = db.folder(id) ?: fail(WorkspaceStoreError.MISSING_FOLDER)
            if (folder.name == trimmed) return@journalledWrite
            db.update(folder.copy(name = trimmed, updatedAt = now))
        }
    }

    suspend fun moveFolder(id: String, toParentFolderId: String?, now: Instant = now()) {
        journalledWrite("Move Folder") { db ->
            val folder = db.folder(id) ?: fail(WorkspaceStoreError.MISSING_FOLDER)
            validateFolderParent(db, folder, toParentFolderId)
            if (folder.parentFolderId == toParentFolderId) return@journalledWrite
            val order = db.nextOrder(
                "list_folders", "workspaceId = ? AND parentFolderId IS ?", folder.workspaceId, toParentFolderId,
            )
            db.update(folder.copy(parentFolderId = toParentFolderId, sortOrder = order, updatedAt = now))
        }
    }

    /** Lists inside are kept (SET NULL moves them to the root); child folders cascade. */
    suspend fun deleteFolder(id: String) {
        journalledWrite("Delete Folder") { db ->
            db.folder(id) ?: fail(WorkspaceStoreError.MISSING_FOLDER)
            db.execute("DELETE FROM list_folders WHERE id = ?", id)
        }
    }

    suspend fun updateList(id: String, name: String, colorHex: String?, now: Instant = now()) {
        val trimmed = nonEmptyName(name)
        val color = colorHex.trimmedOrNull()
        journalledWrite("Edit List") { db ->
            val list = db.list(id) ?: fail(WorkspaceStoreError.MISSING_LIST)
            if (list.name == trimmed && list.colorHex == color) return@journalledWrite
            db.update(list.copy(name = trimmed, colorHex = color, updatedAt = now))
        }
    }

    /** Renames a list and touches nothing else, so undo offers "Rename List". */
    suspend fun renameList(id: String, name: String, now: Instant = now()) {
        val trimmed = nonEmptyName(name)
        journalledWrite("Rename List") { db ->
            val list = db.list(id) ?: fail(WorkspaceStoreError.MISSING_LIST)
            if (list.name == trimmed) return@journalledWrite
            db.update(list.copy(name = trimmed, updatedAt = now))
        }
    }

    suspend fun moveList(id: String, toFolderId: String?, now: Instant = now()) {
        journalledWrite("Move List") { db ->
            val list = db.list(id) ?: fail(WorkspaceStoreError.MISSING_LIST)
            if (toFolderId != null) {
                val folder = db.folder(toFolderId)
                if (folder == null || folder.workspaceId != list.workspaceId) fail(WorkspaceStoreError.MISSING_FOLDER)
            }
            if (list.folderId == toFolderId) return@journalledWrite
            val order = db.nextOrder("task_lists", "workspaceId = ? AND folderId IS ?", list.workspaceId, toFolderId)
            db.update(list.copy(folderId = toFolderId, sortOrder = order, updatedAt = now))
        }
    }

    suspend fun moveListWithinFolder(id: String, by: Int, now: Instant = now()) {
        journalledWrite("Reorder List") { db ->
            val list = db.list(id) ?: fail(WorkspaceStoreError.MISSING_LIST)
            val siblings = listSiblings(db, list.workspaceId, list.folderId, list.isArchived).toMutableList()
            val index = siblings.indexOfFirst { it.id == id }
            if (index < 0) return@journalledWrite
            val target = (index + by).coerceAtLeast(0).coerceAtMost(siblings.size - 1)
            if (target == index) return@journalledWrite
            siblings.add(target, siblings.removeAt(index))
            db.persistListOrder(siblings, now)
        }
    }

    /** Puts [id] before [beforeId] (nil: at the end) among its siblings in [inFolderId]. */
    suspend fun placeList(id: String, beforeId: String?, inFolderId: String?, now: Instant = now()) {
        journalledWrite("Reorder List") { db ->
            var list = db.list(id) ?: fail(WorkspaceStoreError.MISSING_LIST)
            if (id == beforeId) return@journalledWrite
            if (inFolderId != null) {
                val folder = db.folder(inFolderId)
                if (folder == null || folder.workspaceId != list.workspaceId) fail(WorkspaceStoreError.MISSING_FOLDER)
            }
            if (list.folderId != inFolderId) {
                list = list.copy(folderId = inFolderId, updatedAt = now)
                db.update(list)
            }
            val siblings = listSiblings(db, list.workspaceId, inFolderId, list.isArchived).toMutableList()
            val index = siblings.indexOfFirst { it.id == id }
            if (index < 0) return@journalledWrite
            val moved = siblings.removeAt(index)
            val target = beforeId?.let { b -> siblings.indexOfFirst { it.id == b }.takeIf { it >= 0 } } ?: siblings.size
            siblings.add(target, moved)
            db.persistListOrder(siblings, now)
        }
    }

    /** The same placement for folders, refusing a drop inside the folder's own subtree. */
    suspend fun placeFolder(id: String, beforeId: String?, inParentFolderId: String?, now: Instant = now()) {
        journalledWrite("Reorder Folder") { db ->
            var folder = db.folder(id) ?: fail(WorkspaceStoreError.MISSING_FOLDER)
            if (id == beforeId) return@journalledWrite
            if (inParentFolderId != null) {
                val parent = db.folder(inParentFolderId)
                if (parent == null || parent.workspaceId != folder.workspaceId) fail(WorkspaceStoreError.MISSING_FOLDER)
                var ancestor: String? = inParentFolderId
                val visited = HashSet<String>()
                while (ancestor != null && visited.add(ancestor)) {
                    if (ancestor == id) fail(WorkspaceStoreError.INVALID_FOLDER_MOVE)
                    ancestor = db.folder(ancestor)?.parentFolderId
                }
            }
            if (folder.parentFolderId != inParentFolderId) {
                folder = folder.copy(parentFolderId = inParentFolderId, updatedAt = now)
                db.update(folder)
            }
            val siblings = folderSiblings(db, folder.workspaceId, inParentFolderId).toMutableList()
            val index = siblings.indexOfFirst { it.id == id }
            if (index < 0) return@journalledWrite
            val moved = siblings.removeAt(index)
            val target = beforeId?.let { b -> siblings.indexOfFirst { it.id == b }.takeIf { it >= 0 } } ?: siblings.size
            siblings.add(target, moved)
            db.persistFolderOrder(siblings, now)
        }
    }

    suspend fun moveFolderWithinSiblings(id: String, by: Int, now: Instant = now()) {
        journalledWrite("Reorder Folder") { db ->
            val folder = db.folder(id) ?: fail(WorkspaceStoreError.MISSING_FOLDER)
            val siblings = folderSiblings(db, folder.workspaceId, folder.parentFolderId).toMutableList()
            val index = siblings.indexOfFirst { it.id == id }
            if (index < 0) return@journalledWrite
            val target = (index + by).coerceAtLeast(0).coerceAtMost(siblings.size - 1)
            if (target == index) return@journalledWrite
            siblings.add(target, siblings.removeAt(index))
            db.persistFolderOrder(siblings, now)
        }
    }

    suspend fun setListArchived(archived: Boolean, id: String, now: Instant = now()) {
        journalledWrite("Archive List") { db ->
            val list = db.list(id) ?: fail(WorkspaceStoreError.MISSING_LIST)
            if (archived && list.isSystemList) fail(WorkspaceStoreError.SYSTEM_LIST_IS_PERMANENT)
            db.update(list.copy(isArchived = archived, updatedAt = now))
        }
    }

    suspend fun deleteList(id: String) {
        journalledWrite("Delete List") { db ->
            val list = db.list(id) ?: fail(WorkspaceStoreError.MISSING_LIST)
            if (list.isSystemList) fail(WorkspaceStoreError.SYSTEM_LIST_IS_PERMANENT)
            db.execute("DELETE FROM task_lists WHERE id = ?", id)
        }
    }

    // endregion

    // region Tasks (WorkspaceStore.swift)

    suspend fun outline(listId: String, parentTaskId: String? = null): List<TaskOutlineItem> =
        listTree(listId).outline(parentTaskId)

    fun observeOutline(listId: String, parentTaskId: String? = null): Flow<List<TaskOutlineItem>> =
        database.observe(setOf("tasks")) { listTree(it, listId).outline(parentTaskId) }

    /** A parent's direct children, as a project's own board shows them. */
    suspend fun tasks(listId: String, parentTaskId: String? = null): List<WorkspaceTask> =
        database.read { it.taskSiblings(listId, parentTaskId, withId = false) }

    fun observeTasks(listId: String, parentTaskId: String? = null): Flow<List<WorkspaceTask>> =
        database.observe(setOf("tasks")) { it.taskSiblings(listId, parentTaskId, withId = false) }

    /** The imported wrapper standing in for the list's roots, while it is still the only root. */
    suspend fun visibleRootParentTaskId(list: TaskList): String? =
        database.read { visibleRootParentTaskId(it, list.id) }

    /** The virtual Everything scope: every active list's visible roots. */
    suspend fun visibleRootTasks(workspaceId: String): List<WorkspaceTask> = database.read { db ->
        listsIn(db, workspaceId, false).flatMap { list ->
            db.taskSiblings(list.id, visibleRootParentTaskId(db, list.id), withId = false)
        }
    }

    suspend fun createTask(
        listId: String,
        title: String,
        parentTaskId: String? = null,
        kind: WorkspaceItemKind = WorkspaceItemKind.TASK,
        kanbanColumn: String? = null,
        startAt: Instant? = null,
        atTop: Boolean = false,
        adjacentTaskId: String? = null,
        above: Boolean = false,
        dueAt: Instant? = null,
        estimateSeconds: Int? = null,
        tags: List<String> = emptyList(),
        priority: Int? = null,
        now: Instant = now(),
    ): WorkspaceTask {
        val trimmed = nonEmptyName(title)
        val normalizedTags = normalizedStrings(tags)
        val normalizedPriority = priority?.takeIf { it in 1..4 }
        val estimate = estimateSeconds?.takeIf { it > 0 }
        return journalledWrite("New Task") { db ->
            db.list(listId) ?: fail(WorkspaceStoreError.MISSING_LIST)
            if (parentTaskId != null) {
                val parent = db.task(parentTaskId)
                if (parent == null || parent.listId != listId) fail(WorkspaceStoreError.INVALID_TASK_MOVE)
            }
            val order = db.nextOrder("tasks", "listId = ? AND parentTaskId IS ?", listId, parentTaskId)
            val task = WorkspaceTask(
                id = newId(), listId = listId, parentTaskId = parentTaskId, title = trimmed, notes = "",
                status = TaskStatus.OPEN, sortOrder = order, dueAt = dueAt, estimateSeconds = estimate,
                sourceSystem = null, sourceId = null, itemKind = kind, isPromoted = null, archivedAt = null,
                completedAt = null, createdAt = now, updatedAt = now,
            )
            db.insert(task)
            if (kanbanColumn != null || startAt != null || normalizedTags.isNotEmpty() || normalizedPriority != null) {
                db.execute(
                    "INSERT INTO task_metadata(taskId, priority, startAt, tagsJSON, externalLinksJSON, kanbanColumn, " +
                        "updatedAt) VALUES (?, ?, ?, ?, '[]', ?, ?)",
                    task.id, normalizedPriority, startAt, encodeStringArray(normalizedTags), kanbanColumn, now,
                )
            }
            if (atTop || adjacentTaskId != null) {
                val siblings = db.taskSiblings(listId, parentTaskId).filter { it.id != task.id }.toMutableList()
                val insertion = if (adjacentTaskId != null) {
                    val index = siblings.indexOfFirst { it.id == adjacentTaskId }
                    if (index < 0) fail(WorkspaceStoreError.INVALID_TASK_MOVE)
                    index + if (above) 0 else 1
                } else {
                    0
                }
                siblings.add(insertion, task)
                db.persistTaskOrder(siblings, now)
            }
            db.task(task.id) ?: task
        }
    }

    /** Closing one occurrence of a repeating task writes the next one. */
    suspend fun setStatus(status: TaskStatus, taskId: String, now: Instant = now()) {
        journalledWrite("Change Status") { db ->
            val existing = db.task(taskId) ?: return@journalledWrite
            // Only stamp a task that is newly closed.
            val wasOpen = existing.completedAt == null
            val task = existing.copy(
                status = status,
                completedAt = if (status == TaskStatus.OPEN) null else (existing.completedAt ?: now),
                updatedAt = now,
            )
            db.update(task)
            // Closing one occurrence of a repeating task writes the next one,
            // and ends the habits made from it.
            if (status != TaskStatus.OPEN && wasOpen) {
                scheduleNextOccurrence(db, task, now, zone)
                expireHabits(db, task.id, now)
            }
        }
    }

    suspend fun updateTask(
        id: String,
        title: String,
        notes: String,
        dueAt: Instant?,
        estimateSeconds: Int?,
        now: Instant = now(),
    ) {
        val trimmed = nonEmptyName(title)
        journalledWrite("Edit Task") { db ->
            val previous = taskEditorSnapshot(db, id)
            var planning = previous.planning
            if (dueAt != null) planning = planning?.copy(dueDate = null)?.normalized
            val edit = previous.copy(
                title = trimmed, notes = notes, dueAt = dueAt, estimateSeconds = estimateSeconds, planning = planning,
            )
            updatePlanning(db, edit, previous.planning, previous.dueAt, now, zone)
            updateTaskRecord(db, edit, now)
        }
    }

    suspend fun taskEditorMetadata(taskId: String): TaskEditorMetadata =
        database.read { taskEditorSnapshot(it, taskId).metadata }

    suspend fun updateTaskEditorMetadata(taskId: String, metadata: TaskEditorMetadata, now: Instant = now()) {
        journalledWrite("Edit Task Details") { db -> updateEditorMetadata(db, taskId, metadata, now) }
    }

    suspend fun kanbanColumn(taskId: String): String? = database.read { it.metadata(taskId)?.kanbanColumn }

    /** Board placement for many cards in one read; missing metadata means unplaced. */
    suspend fun boardMetadata(taskIds: List<String>): BoardMetadata {
        if (taskIds.isEmpty()) return BoardMetadata(emptyMap(), emptyMap())
        return database.read { db ->
            val columns = HashMap<String, String>()
            val positions = taskIds.toSet().associateWith { TaskMatrixPosition(null, null) }.toMutableMap()
            for (chunk in taskIds.chunked(500)) {
                val records = db.query(
                    "SELECT * FROM task_metadata WHERE taskId IN (${chunk.joinToString(",") { "?" }})",
                    *chunk.toTypedArray(),
                ) { it.toMetadata() }
                for (record in records) {
                    record.kanbanColumn?.let { columns[record.taskId] = it }
                    positions[record.taskId] = TaskMatrixPosition(record.matrixUrgency, record.matrixImportance)
                }
            }
            BoardMetadata(columns, positions)
        }
    }

    suspend fun setKanbanColumn(column: String?, taskId: String, now: Instant = now()) =
        setKanbanColumn(column, listOf(taskId), now)

    /** Moving a whole column is one transaction and one undo step. */
    suspend fun setKanbanColumn(column: String?, taskIds: List<String>, now: Instant = now()) {
        val ids = taskIds.distinct()
        if (ids.isEmpty()) return
        val value = column.trimmedOrNull()
        journalledWrite("Move Task") { db ->
            for (chunk in ids.chunked(500)) {
                val count = db.int(
                    "SELECT COUNT(*) FROM tasks WHERE id IN (${chunk.joinToString(",") { "?" }})",
                    *chunk.toTypedArray(),
                ) ?: 0
                if (count != chunk.size) fail(WorkspaceStoreError.MISSING_TASK)
            }
            for (id in ids) upsertKanbanColumn(db, id, value, now)
        }
    }

    suspend fun matrixPosition(taskId: String): TaskMatrixPosition = database.read { db ->
        val metadata = db.metadata(taskId)
        TaskMatrixPosition(metadata?.matrixUrgency, metadata?.matrixImportance)
    }

    suspend fun setMatrixPosition(position: TaskMatrixPosition, taskId: String, now: Instant = now()) {
        journalledWrite("Move Task") { db ->
            db.task(taskId) ?: fail(WorkspaceStoreError.MISSING_TASK)
            val record = (db.metadata(taskId) ?: emptyMetadata(taskId, now)).copy(
                matrixUrgency = position.urgency, matrixImportance = position.importance, updatedAt = now,
            )
            db.save(record)
        }
    }

    /** Moves a task and its subtree; the destination parent must be in the destination list and outside the subtree. */
    suspend fun moveTask(
        id: String,
        toListId: String,
        parentTaskId: String? = null,
        toVisibleRoot: Boolean = false,
        now: Instant = now(),
    ) {
        journalledWrite("Move Task") { db ->
            var task = db.task(id) ?: fail(WorkspaceStoreError.MISSING_TASK)
            db.list(toListId) ?: fail(WorkspaceStoreError.MISSING_LIST)
            val parent = if (toVisibleRoot) visibleRootParentTaskId(db, toListId) else parentTaskId
            val descendants = db.taskDescendantIDs(id)
            if (parent == id || (parent != null && parent in descendants)) fail(WorkspaceStoreError.INVALID_TASK_MOVE)
            if (parent != null) {
                val parentTask = db.task(parent)
                if (parentTask == null || parentTask.listId != toListId) fail(WorkspaceStoreError.INVALID_TASK_MOVE)
            }
            if (task.listId == toListId && task.parentTaskId == parent) return@journalledWrite
            if (task.listId != toListId) {
                moveSubtree(db, descendants + id, toListId, now)
                task = task.copy(listId = toListId)
            }
            val order = db.nextOrder("tasks", "listId = ? AND parentTaskId IS ?", toListId, parent)
            db.update(task.copy(parentTaskId = parent, sortOrder = order, updatedAt = now))
        }
    }

    suspend fun moveTaskWithinSiblings(id: String, by: Int, now: Instant = now()) {
        journalledWrite("Reorder Task") { db ->
            val task = db.task(id) ?: fail(WorkspaceStoreError.MISSING_TASK)
            val siblings = db.taskSiblings(task.listId, task.parentTaskId, withId = false).toMutableList()
            val index = siblings.indexOfFirst { it.id == id }
            if (index < 0) return@journalledWrite
            val target = (index + by).coerceAtLeast(0).coerceAtMost(siblings.size - 1)
            if (target == index) return@journalledWrite
            siblings.add(target, siblings.removeAt(index))
            db.persistTaskOrder(siblings, now)
        }
    }

    /** Puts a task first among its siblings. */
    suspend fun moveTaskToStart(id: String, now: Instant = now()) {
        journalledWrite("Reorder Task") { db ->
            val task = db.task(id) ?: fail(WorkspaceStoreError.MISSING_TASK)
            val siblings = db.taskSiblings(task.listId, task.parentTaskId, withId = false).toMutableList()
            val index = siblings.indexOfFirst { it.id == id }
            if (index <= 0) return@journalledWrite
            siblings.add(0, siblings.removeAt(index))
            db.persistTaskOrder(siblings, now)
        }
    }

    /** Reorders a card before another card of the same parent, optionally filing it in [kanbanColumn]. */
    suspend fun moveTaskBefore(id: String, targetId: String, kanbanColumn: String? = null, now: Instant = now()) {
        journalledWrite("Reorder Task") { db ->
            val task = db.task(id) ?: fail(WorkspaceStoreError.MISSING_TASK)
            val target = db.task(targetId) ?: fail(WorkspaceStoreError.MISSING_TASK)
            if (task.listId != target.listId || task.parentTaskId != target.parentTaskId) {
                fail(WorkspaceStoreError.INVALID_TASK_MOVE)
            }
            if (id == targetId) return@journalledWrite
            val siblings = db.taskSiblings(task.listId, task.parentTaskId, withId = false).toMutableList()
            val index = siblings.indexOfFirst { it.id == id }
            if (index < 0) return@journalledWrite
            val moved = siblings.removeAt(index)
            val targetIndex = siblings.indexOfFirst { it.id == targetId }
            if (targetIndex < 0) return@journalledWrite
            siblings.add(targetIndex, moved)
            db.persistTaskOrder(siblings, now)
            if (kanbanColumn != null) upsertKanbanColumn(db, id, kanbanColumn, now)
        }
    }

    /** Makes the task a child of its immediately preceding sibling. */
    suspend fun indentTask(id: String, now: Instant = now()) {
        journalledWrite("Indent Task") { db ->
            val task = db.task(id) ?: fail(WorkspaceStoreError.MISSING_TASK)
            val siblings = db.taskSiblings(task.listId, task.parentTaskId, withId = false)
            val index = siblings.indexOfFirst { it.id == id }
            if (index <= 0) return@journalledWrite
            val newParent = siblings[index - 1]
            val order = db.nextOrder("tasks", "listId = ? AND parentTaskId IS ?", task.listId, newParent.id)
            db.update(task.copy(parentTaskId = newParent.id, sortOrder = order, updatedAt = now))
            db.persistTaskOrder(siblings.filter { it.id != id }, now)
        }
    }

    /** Promotes a task one level, immediately after its former parent. */
    suspend fun outdentTask(id: String, now: Instant = now()) {
        journalledWrite("Outdent Task") { db ->
            val task = db.task(id) ?: fail(WorkspaceStoreError.MISSING_TASK)
            val parentId = task.parentTaskId ?: return@journalledWrite
            val parent = db.task(parentId) ?: return@journalledWrite
            val newParentId = parent.parentTaskId
            val targetSiblings = db.taskSiblings(task.listId, newParentId, withId = false).toMutableList()
            val parentIndex = targetSiblings.indexOfFirst { it.id == parentId }.takeIf { it >= 0 }
                ?: (targetSiblings.size - 1)
            targetSiblings.add(
                minOf(parentIndex + 1, targetSiblings.size),
                task.copy(parentTaskId = newParentId, updatedAt = now),
            )
            db.persistTaskOrder(targetSiblings, now)
        }
    }

    suspend fun deleteTask(id: String) {
        journalledWrite("Delete Task") { db ->
            db.task(id) ?: fail(WorkspaceStoreError.MISSING_TASK)
            db.execute("DELETE FROM tasks WHERE id = ?", id)
        }
    }

    // endregion

    // region Lists as tasks (WorkspaceStore+Lists.swift)

    /** Turns an item into a standalone list in [folderId] (nil: the top level), keeping its subtree. */
    suspend fun moveTaskToFolder(id: String, folderId: String?, now: Instant = now()): TaskList =
        journalledWrite(if (folderId == null) "Move Item to Top Level" else "Move Item to Folder") { db ->
            val task = db.task(id) ?: fail(WorkspaceStoreError.MISSING_TASK)
            val source = db.list(task.listId) ?: fail(WorkspaceStoreError.MISSING_TASK)
            if (folderId != null) {
                val folder = db.folder(folderId)
                if (folder == null || folder.workspaceId != source.workspaceId) fail(WorkspaceStoreError.MISSING_FOLDER)
            }
            // Do not extract a transport wrapper and leave a broken source list.
            if (source.visibleRootTaskId == id) fail(WorkspaceStoreError.INVALID_TASK_MOVE)
            val destination = TaskList(
                id = newId(), workspaceId = source.workspaceId, folderId = folderId, name = task.title,
                colorHex = source.colorHex,
                sortOrder = db.nextOrder("task_lists", "workspaceId = ? AND folderId IS ?", source.workspaceId, folderId),
                isArchived = task.isList && task.archivedAt != null, systemRole = null, visibleRootTaskId = task.id,
                completedAt = if (task.isList && task.status != TaskStatus.OPEN) now else null,
                createdAt = now, updatedAt = now,
            )
            db.insert(destination)
            moveSubtree(db, db.taskDescendantIDs(id) + id, destination.id, now)
            val order = db.nextOrder("tasks", "listId = ? AND parentTaskId IS ?", destination.id, null)
            db.update(
                task.copy(
                    listId = destination.id, parentTaskId = null, sortOrder = order, itemKind = WorkspaceItemKind.LIST,
                    isPromoted = null, archivedAt = null, status = TaskStatus.OPEN, updatedAt = now,
                ),
            )
            destination
        }

    /** A standalone list becomes one task in Inbox, keeping its children, metadata and hierarchy. */
    suspend fun convertListToTask(id: String, now: Instant = now()): WorkspaceTask =
        journalledWrite("Convert List to Task") { db ->
            val list = db.list(id) ?: fail(WorkspaceStoreError.MISSING_LIST)
            if (list.isSystemList) fail(WorkspaceStoreError.SYSTEM_LIST_IS_PERMANENT)
            val inbox = inbox(db, list.workspaceId) ?: fail(WorkspaceStoreError.MISSING_LIST)
            relocateList(db, list, inbox, null, WorkspaceItemKind.TASK, now)
        }

    /** Drops a standalone list into another list as a nested list. */
    suspend fun nestList(id: String, inListId: String, parentTaskId: String? = null, now: Instant = now()): WorkspaceTask =
        journalledWrite("Move List into List") { db ->
            val list = db.list(id) ?: fail(WorkspaceStoreError.MISSING_LIST)
            val destination = db.list(inListId) ?: fail(WorkspaceStoreError.MISSING_LIST)
            if (list.isSystemList) fail(WorkspaceStoreError.SYSTEM_LIST_IS_PERMANENT)
            if (id == inListId || list.workspaceId != destination.workspaceId) fail(WorkspaceStoreError.INVALID_TASK_MOVE)
            val parentId = parentTaskId ?: destination.visibleRootTaskId?.let { rootId ->
                val roots = db.query("SELECT id FROM tasks WHERE listId = ? AND parentTaskId IS NULL", inListId) {
                    it.string("id")
                }
                if (roots.size == 1 && roots.first() == rootId) rootId else null
            }
            if (parentId != null) {
                val parent = db.task(parentId)
                if (parent == null || parent.listId != inListId ||
                    !(parent.isList || parent.id == destination.visibleRootTaskId)
                ) {
                    fail(WorkspaceStoreError.INVALID_TASK_MOVE)
                }
            }
            relocateList(db, list, destination, parentId, WorkspaceItemKind.LIST, now)
        }

    suspend fun setItemKind(kind: WorkspaceItemKind, id: String, now: Instant = now()) {
        journalledWrite(if (kind == WorkspaceItemKind.LIST) "Convert to List" else "Convert to Task") { db ->
            val task = db.task(id) ?: fail(WorkspaceStoreError.MISSING_TASK)
            if ((task.itemKind ?: WorkspaceItemKind.TASK) == kind) return@journalledWrite
            if ((db.int("SELECT COUNT(*) FROM task_lists WHERE visibleRootTaskId = ?", id) ?: 0) != 0) {
                fail(WorkspaceStoreError.INVALID_TASK_MOVE)
            }
            if ((db.int("SELECT COUNT(*) FROM focus_sessions WHERE activeTaskId = ? AND phase != 'finished'", id) ?: 0) != 0) {
                fail(WorkspaceStoreError.INVALID_TASK_MOVE)
            }
            var updated = task.copy(itemKind = kind, updatedAt = now)
            if (kind == WorkspaceItemKind.TASK) updated = updated.copy(isPromoted = null, archivedAt = null)
            db.update(updated)
        }
    }

    suspend fun setNestedListPromoted(promoted: Boolean, id: String, now: Instant = now()) {
        journalledWrite(if (promoted) "Promote List" else "Unpin List") { db ->
            val task = db.task(id)?.takeIf { it.isList } ?: fail(WorkspaceStoreError.MISSING_LIST)
            if ((task.isPromoted == true) == promoted) return@journalledWrite
            db.update(task.copy(isPromoted = promoted, updatedAt = now))
        }
    }

    suspend fun setNestedListArchived(archived: Boolean, id: String, now: Instant = now()) {
        journalledWrite(if (archived) "Archive Nested List" else "Restore Nested List") { db ->
            val task = db.task(id)?.takeIf { it.isList } ?: fail(WorkspaceStoreError.MISSING_LIST)
            if ((task.archivedAt != null) == archived) return@journalledWrite
            db.update(task.copy(archivedAt = if (archived) now else null, updatedAt = now))
        }
    }

    suspend fun setListCompleted(completed: Boolean, id: String, now: Instant = now()) {
        journalledWrite(if (completed) "Complete List" else "Reopen List") { db ->
            val list = db.list(id) ?: fail(WorkspaceStoreError.MISSING_LIST)
            if (list.isSystemList) fail(WorkspaceStoreError.SYSTEM_LIST_IS_PERMANENT)
            if ((list.completedAt != null) == completed) return@journalledWrite
            db.update(list.copy(completedAt = if (completed) now else null, updatedAt = now))
        }
    }

    /** Open, doable tasks across the workspace's active lists, or only [limitedTo] in that order. */
    suspend fun actionableTasks(workspaceId: String, limitedTo: List<String>? = null): List<WorkspaceTask> =
        database.read { actionableTasks(it, workspaceId, limitedTo) }

    fun observeActionableTasks(workspaceId: String, limitedTo: List<String>? = null): Flow<List<WorkspaceTask>> =
        database.observe(setOf("tasks", "task_lists")) { actionableTasks(it, workspaceId, limitedTo) }

    suspend fun visibleOutline(listId: String, parentTaskId: String? = null): List<TaskOutlineItem> =
        listTree(listId).visibleOutline(parentTaskId)

    fun observeVisibleOutline(listId: String, parentTaskId: String? = null): Flow<List<TaskOutlineItem>> =
        database.observe(setOf("tasks")) { listTree(it, listId).visibleOutline(parentTaskId) }

    /** The board configurations, seeding [legacy] and the defaults for [currentKey] without an undo step. */
    suspend fun kanbanBoardConfigurations(
        legacy: Map<String, String> = emptyMap(),
        currentKey: String,
    ): Map<String, List<WorkspaceKanbanColumn>> = database.write { db ->
        val baseline = legacy.toMutableMap()
        if (currentKey !in baseline) baseline[currentKey] = KanbanColumnsCodec.encode(WorkspaceKanbanColumn.blitzitDefaults)
        for ((key, json) in baseline) {
            val columns = KanbanColumnsCodec.decode(json)
            if (columns.isNullOrEmpty()) continue
            db.execute("INSERT OR IGNORE INTO kanban_boards(id, columnsJSON) VALUES (?, ?)", key, json)
        }
        db.query("SELECT id, columnsJSON FROM kanban_boards") { it.string("id") to it.string("columnsJSON") }
            .mapNotNull { (key, json) -> KanbanColumnsCodec.decode(json)?.let { key to it } }
            .toMap()
    }

    fun observeKanbanBoards(): Flow<Map<String, List<WorkspaceKanbanColumn>>> =
        database.observe(setOf("kanban_boards")) { db ->
            db.query("SELECT id, columnsJSON FROM kanban_boards") { it.string("id") to it.string("columnsJSON") }
                .mapNotNull { (key, json) -> KanbanColumnsCodec.decode(json)?.let { key to it } }
                .toMap()
        }

    /** A removed column and the cards moved out of it form one undo step. */
    suspend fun setKanbanBoardColumns(
        columns: List<WorkspaceKanbanColumn>,
        key: String,
        movingTaskIds: List<String> = emptyList(),
        toColumn: String? = null,
        label: String = "Edit Board",
        now: Instant = now(),
    ) {
        if (columns.isEmpty()) return
        val json = KanbanColumnsCodec.encode(columns)
        journalledWrite(label) { db ->
            for (id in movingTaskIds.distinct()) {
                db.task(id) ?: fail(WorkspaceStoreError.MISSING_TASK)
                upsertKanbanColumn(db, id, toColumn, now)
            }
            db.execute(
                "INSERT INTO kanban_boards(id, columnsJSON) VALUES (?, ?) " +
                    "ON CONFLICT(id) DO UPDATE SET columnsJSON = excluded.columnsJSON " +
                    "WHERE columnsJSON != excluded.columnsJSON",
                key, json,
            )
        }
    }

    // endregion

    // region List trees (WorkspaceListTree.swift)

    suspend fun listTree(listId: String): WorkspaceListTree = database.read { listTree(it, listId) }

    /** Several lists' rows in one read transaction, so a combined scope sees one moment. */
    suspend fun listTrees(listIds: List<String>): Map<String, WorkspaceListTree> {
        if (listIds.isEmpty()) return emptyMap()
        return database.read { db -> listIds.toSet().associateWith { listTree(db, it) } }
    }

    fun observeListTrees(listIds: List<String>): Flow<Map<String, WorkspaceListTree>> =
        database.observe(setOf("tasks")) { db -> listIds.toSet().associateWith { listTree(db, it) } }

    /** Tasks by id, in one read; missing ids are absent. */
    suspend fun tasks(ids: List<String>): Map<String, WorkspaceTask> {
        if (ids.isEmpty()) return emptyMap()
        return database.read { tasksById(it, ids) }
    }

    // endregion

    // region External writes (WorkspaceStore+ExternalWrites.swift)

    /** `PRAGMA data_version` on the writer: moves only when another connection or process commits. */
    suspend fun externalChangeToken(): Long =
        database.writerWithoutTransaction { it.long("PRAGMA data_version") ?: 0L }

    // endregion

    // region Editing (WorkspaceStore+Editing.swift)

    suspend fun taskEditorSnapshot(taskId: String): TaskEditorSnapshot = database.read { taskEditorSnapshot(it, taskId) }

    fun observeTaskEditorSnapshot(taskId: String): Flow<TaskEditorSnapshot?> =
        database.observe(setOf("tasks", "task_lists", "task_metadata", "dailies")) { db ->
            runCatching { taskEditorSnapshot(db, taskId) }.getOrNull()
        }

    /** Saves the inspector's draft; throws CONFLICTING_CHANGES if the task changed underneath it. */
    suspend fun saveTaskEditor(draft: TaskEditorDraft, now: Instant = now()): TaskEditorSnapshot {
        val edit = draft.validatedSnapshot()
        return journalledWrite("Edit Task") { db ->
            val current = taskEditorSnapshot(db, edit.taskId)
            if (current != draft.baseline) throw TaskEditorException(TaskEditorError.CONFLICTING_CHANGES)
            updatePlanning(db, edit, current.planning, current.dueAt, now, zone)
            updateTaskRecord(db, edit, now)
            updateEditorMetadata(db, edit.taskId, edit.metadata, now)
            setDailyAttachment(db, edit.taskId, edit.dailyProgress, edit.estimateSeconds, now)
            taskEditorSnapshot(db, edit.taskId)
        }
    }

    /** Folders [folderId] may move under: everything but itself and its subtree. */
    suspend fun validParentFolders(folderId: String): List<ListFolder> = database.read { db ->
        val folder = db.folder(folderId) ?: fail(WorkspaceStoreError.MISSING_FOLDER)
        val excluded = db.folderDescendantIDs(folderId) + folderId
        foldersIn(db, folder.workspaceId).filter { it.id !in excluded }
    }

    suspend fun saveFolderSettings(id: String, name: String, parentFolderId: String?, now: Instant = now()) {
        val trimmed = nonEmptyName(name)
        journalledWrite("Edit Folder") { db ->
            val folder = db.folder(id) ?: fail(WorkspaceStoreError.MISSING_FOLDER)
            validateFolderParent(db, folder, parentFolderId)
            if (folder.name == trimmed && folder.parentFolderId == parentFolderId) return@journalledWrite
            val order = if (folder.parentFolderId != parentFolderId) {
                db.nextOrder("list_folders", "workspaceId = ? AND parentFolderId IS ?", folder.workspaceId, parentFolderId)
            } else {
                folder.sortOrder
            }
            db.update(folder.copy(name = trimmed, parentFolderId = parentFolderId, sortOrder = order, updatedAt = now))
        }
    }

    /** The only root that may serve as the list's visible root, if there is one. */
    suspend fun visibleRootCandidates(listId: String): List<WorkspaceTask> = database.read { db ->
        val roots = db.query("SELECT * FROM tasks WHERE listId = ? AND parentTaskId IS NULL", listId) { it.toTask() }
        val root = roots.singleOrNull() ?: return@read emptyList()
        if (root.sourceSystem == null && !root.isList) return@read emptyList()
        if (!root.isList && !db.exists("SELECT 1 FROM tasks WHERE parentTaskId = ?", root.id)) return@read emptyList()
        listOf(root)
    }

    suspend fun saveListSettings(
        id: String,
        name: String,
        colorHex: String?,
        folderId: String?,
        isArchived: Boolean,
        visibleRootTaskId: String?,
        now: Instant = now(),
    ) {
        val trimmed = nonEmptyName(name)
        val color = colorHex.trimmedOrNull()
        journalledWrite("Edit List") { db ->
            val list = db.list(id) ?: fail(WorkspaceStoreError.MISSING_LIST)
            if (folderId != null) {
                val folder = db.folder(folderId)
                if (folder == null || folder.workspaceId != list.workspaceId) fail(WorkspaceStoreError.MISSING_FOLDER)
            }
            if (isArchived && list.isSystemList) fail(WorkspaceStoreError.SYSTEM_LIST_IS_PERMANENT)
            if (list.visibleRootTaskId != visibleRootTaskId) validateVisibleRoot(db, id, visibleRootTaskId)
            if (list.name == trimmed && list.colorHex == color && list.folderId == folderId &&
                list.isArchived == isArchived && list.visibleRootTaskId == visibleRootTaskId
            ) {
                return@journalledWrite
            }
            val order = if (list.folderId != folderId) {
                db.nextOrder("task_lists", "workspaceId = ? AND folderId IS ?", list.workspaceId, folderId)
            } else {
                list.sortOrder
            }
            db.update(
                list.copy(
                    name = trimmed, colorHex = color, folderId = folderId, isArchived = isArchived,
                    visibleRootTaskId = visibleRootTaskId, sortOrder = order, updatedAt = now,
                ),
            )
        }
    }

    private fun validateVisibleRoot(db: Db, listId: String, rootId: String?) {
        rootId ?: return
        val roots = db.query("SELECT * FROM tasks WHERE listId = ? AND parentTaskId IS NULL", listId) { it.toTask() }
        val root = roots.singleOrNull()
        val valid = root != null && root.id == rootId && (root.sourceSystem != null || root.isList) &&
            (root.isList || db.exists("SELECT 1 FROM tasks WHERE parentTaskId = ?", rootId))
        if (!valid) throw TaskEditorException(TaskEditorError.INVALID_VISIBLE_ROOT)
    }

    // endregion

    // region Conditions (WorkspaceStore+Conditions.swift)

    suspend fun conditions(workspaceId: String): List<TaskCondition> = database.read { conditionsIn(it, workspaceId) }

    fun observeConditions(workspaceId: String): Flow<List<TaskCondition>> =
        database.observe(setOf("task_conditions")) { conditionsIn(it, workspaceId) }

    suspend fun createCondition(
        workspaceId: String,
        name: String,
        isLocation: Boolean = false,
        now: Instant = now(),
    ): TaskCondition {
        val trimmed = nonEmptyName(name)
        return journalledWrite("New Condition") { db ->
            db.workspace(workspaceId) ?: planningFail(TaskPlanningError.INVALID_CONDITION)
            TaskCondition(newId(), workspaceId, trimmed, isLocation, false, now, now).also { db.insert(it) }
        }
    }

    suspend fun saveCondition(id: String, name: String, isLocation: Boolean, isArchived: Boolean, now: Instant = now()) {
        val trimmed = nonEmptyName(name)
        journalledWrite("Edit Condition") { db ->
            val record = db.condition(id) ?: planningFail(TaskPlanningError.INVALID_CONDITION)
            if (record.name == trimmed && record.isLocation == isLocation && record.isArchived == isArchived) {
                return@journalledWrite
            }
            db.update(record.copy(name = trimmed, isLocation = isLocation, isArchived = isArchived, updatedAt = now))
        }
    }

    /** Copies a task's requirements, start and block rules (not due dates) onto every descendant. */
    suspend fun applyPlanningToDescendants(taskId: String, now: Instant = now()) {
        journalledWrite("Apply Planning to Subtasks") { db ->
            val parent = taskEditorSnapshot(db, taskId)
            for (id in db.taskDescendantIDs(taskId)) {
                val saved = taskEditorSnapshot(db, id)
                val planning = parent.planning?.copy(dueDate = saved.planning?.dueDate)
                updatePlanning(db, saved.copy(planning = planning), null, now = now, zone = zone)
            }
        }
    }

    /** Every task's planning, keyed by task id. */
    suspend fun taskPlanningValues(): Map<String, TaskPlanning> = database.read { taskPlanningValues(it) }

    // endregion

    // region Dailies (WorkspaceStore+Dailies.swift)

    /** Every non-archived daily due on [day], with its task and that day's contribution. */
    suspend fun dailies(day: Instant = now(), zone: ZoneId = this.zone): List<DailyItem> =
        database.read { dailiesOn(it, day, zone) }

    fun observeDailies(day: Instant = now(), zone: ZoneId = this.zone): Flow<List<DailyItem>> =
        database.observe(setOf("dailies", "daily_contributions", "tasks")) { dailiesOn(it, day, zone) }

    /** Every daily regardless of schedule. */
    suspend fun allDailies(): List<WorkspaceDaily> = database.read { db ->
        db.query("SELECT * FROM dailies WHERE archivedAt IS NULL ORDER BY sortOrder, createdAt") { it.toDaily() }
    }

    suspend fun daily(taskId: String): WorkspaceDaily? = database.read { db ->
        db.queryOne("SELECT * FROM dailies WHERE taskId = ? AND archivedAt IS NULL", taskId) { it.toDaily() }
    }

    /** Makes the task a daily, or returns (and revives) the one it already has. */
    suspend fun makeDaily(
        taskId: String,
        weekdays: Set<Int> = (1..7).toSet(),
        intervalDays: Int? = null,
        targetSeconds: Int? = null,
        now: Instant = now(),
    ): WorkspaceDaily = journalledWrite("Make Daily") { db ->
        makeDailyRecord(db, taskId, weekdays, intervalDays, targetSeconds, now)
    }

    /** Archives rather than deletes, so logged contributions keep a parent. */
    suspend fun archiveDaily(taskId: String, now: Instant = now()) {
        journalledWrite("Archive Daily") { db -> archiveDailyRecord(db, taskId, now) }
    }

    /**
     * Edits a daily's schedule. An argument left as [FieldEdit.Keep] keeps its value;
     * `intervalDays = FieldEdit.To(null)` switches back to weekdays.
     */
    suspend fun updateDaily(
        id: String,
        weekdays: Set<Int>? = null,
        intervalDays: FieldEdit<Int?> = FieldEdit.Keep,
        targetSeconds: FieldEdit<Int?> = FieldEdit.Keep,
        now: Instant = now(),
    ) {
        journalledWrite("Edit Daily") { db ->
            var daily = db.daily(id) ?: return@journalledWrite
            if (weekdays != null && weekdays.isNotEmpty()) {
                daily = daily.copy(activeWeekdaysMask = WorkspaceDaily.mask(weekdays))
            }
            if (intervalDays is FieldEdit.To) {
                val interval = intervalDays.value?.coerceIn(1, 366)
                daily = daily.copy(
                    intervalDays = interval,
                    intervalAnchor = if (intervalDays.value == null) null else (daily.intervalAnchor ?: now),
                )
            }
            if (targetSeconds is FieldEdit.To) daily = daily.copy(targetSeconds = targetSeconds.value)
            db.update(daily.copy(updatedAt = now))
        }
    }

    /** Records progress for today, accumulating onto any contribution already logged. */
    suspend fun logContribution(
        dailyId: String,
        seconds: Int = 0,
        complete: Boolean = true,
        now: Instant = now(),
        zone: ZoneId = this.zone,
    ): DailyContribution = journalledWrite("Log Daily") { db ->
        val daily = db.daily(dailyId) ?: fail(WorkspaceStoreError.MISSING_DAILY)
        recordContribution(db, daily, seconds, complete, now, zone)
    }

    /** Un-ticks a day without discarding the time already logged against it. */
    suspend fun clearContribution(dailyId: String, day: Instant = now(), zone: ZoneId = this.zone) {
        val key = DailyContribution.dayKey(day, zone)
        journalledWrite("Clear Daily") { db ->
            val contribution = db.queryOne(
                "SELECT * FROM daily_contributions WHERE dailyId = ? AND dayKey = ?", dailyId, key,
            ) { it.toContribution() } ?: return@journalledWrite
            db.update(contribution.copy(completedAt = null))
        }
    }

    /** Contributions over the last [days] days ending on [endingOn], oldest first. */
    suspend fun contributionHistory(
        dailyId: String,
        days: Int,
        endingOn: Instant = now(),
        zone: ZoneId = this.zone,
    ): List<DailyContribution> {
        val keys = (0 until maxOf(1, days)).map { offset ->
            DailyContribution.dayKey(endingOn.atZone(zone).minusDays(offset.toLong()).toInstant(), zone)
        }
        return database.read { db ->
            keys.chunked(500).flatMap { chunk ->
                db.query(
                    "SELECT * FROM daily_contributions WHERE dailyId = ? AND dayKey IN (${chunk.joinToString(",") { "?" }})",
                    dailyId, *chunk.toTypedArray(),
                ) { it.toContribution() }
            }.sortedBy { it.dayKey }
        }
    }

    /** How many things are finished today (this one included), and the streak of days ending today. */
    suspend fun completionContext(now: Instant = now(), zone: ZoneId = this.zone): CompletionContext =
        database.read { db ->
            val today = now.atZone(zone).toLocalDate()
            fun start(date: java.time.LocalDate) = date.atStartOfDay(zone).toInstant()
            fun finishedOn(date: java.time.LocalDate) = db.int(
                "SELECT COUNT(*) FROM tasks WHERE status = ? AND updatedAt >= ? AND updatedAt < ?",
                TaskStatus.COMPLETED.raw, start(date), start(date.plusDays(1)),
            ) ?: 0
            fun tickedOn(key: String) = db.int(
                "SELECT COUNT(*) FROM daily_contributions WHERE dayKey = ? AND completedAt IS NOT NULL", key,
            ) ?: 0
            val ordinal = finishedOn(today) + tickedOn(DailyContribution.dayKey(now, zone)) + 1
            var streak = 0
            for (offset in 0 until 366) {
                val day = today.minusDays(offset.toLong())
                val total = finishedOn(day) + tickedOn(DailyContribution.dayKey(start(day), zone))
                if (total > 0 || offset == 0) streak += 1 else break
            }
            CompletionContext(ordinal, streak)
        }

    // endregion

    // region Next up and the focus order (WorkspaceStore+Dailies.swift)

    /** Every open task that could be done now, shaped for `NextUpSelector`. */
    suspend fun nextUpCandidates(now: Instant = now(), zone: ZoneId = this.zone): List<NextUpCandidate> =
        database.read { focusCandidates(it, now, zone) }

    /** Pins one task to [atIndex] in the ladder, leaving the rest to the ranking. */
    suspend fun pinTask(taskId: String, atIndex: Int, now: Instant = now()) {
        journalledWrite("Pin Task") { db ->
            db.task(taskId) ?: fail(WorkspaceStoreError.MISSING_TASK)
            val rank = maxOf(0, atIndex)
            val metadata = db.metadata(taskId)
            if (metadata != null) {
                db.update(metadata.copy(focusRank = rank, updatedAt = now))
            } else {
                db.insert(emptyMetadata(taskId, now).copy(focusRank = rank))
            }
        }
    }

    /** Releases one task back to the ranking. */
    suspend fun unpinTask(taskId: String, now: Instant = now()) {
        journalledWrite("Unpin Task") { db ->
            val metadata = db.metadata(taskId) ?: return@journalledWrite
            db.update(metadata.copy(focusRank = null, updatedAt = now))
        }
    }

    /** Hands the ladder back to the ranking. */
    suspend fun clearFocusOrder(now: Instant = now()) {
        journalledWrite("Clear Focus Order") { db ->
            db.execute("UPDATE task_metadata SET focusRank = NULL, updatedAt = ? WHERE focusRank IS NOT NULL", now)
        }
    }

    suspend fun hasManualFocusOrder(): Boolean = database.read { hasManualFocusOrder(it) }

    /** "Schedule it for later": sets the task's start. */
    suspend fun scheduleTask(id: String, startAt: Instant?, now: Instant = now()) {
        journalledWrite("Schedule Task") { db ->
            val previous = taskEditorSnapshot(db, id)
            val plan = (previous.planning ?: TaskPlanning()).copy(startAt = startAt)
            updatePlanning(db, previous.copy(planning = plan.normalized), previous.planning, previous.dueAt, now, zone)
        }
    }

    // endregion

    // region Today (WorkspaceStore+Today.swift)

    /** Puts each task in the Today column, or takes it out (dropping its hand-placed rank). */
    suspend fun setPlannedForToday(planned: Boolean, taskIds: List<String>, now: Instant = now()) {
        if (taskIds.isEmpty()) return
        journalledWrite(if (planned) "Plan for Today" else "Take off Today") { db ->
            for (taskId in taskIds) {
                db.task(taskId) ?: fail(WorkspaceStoreError.MISSING_TASK)
                val record = db.metadata(taskId) ?: emptyMetadata(taskId, now)
                val isPlanned = record.kanbanColumn == NextUpSelector.todayColumnID
                if (isPlanned == planned) continue
                db.save(
                    record.copy(
                        kanbanColumn = if (planned) NextUpSelector.todayColumnID else null,
                        focusRank = if (planned) record.focusRank else null,
                        updatedAt = now,
                    ),
                )
            }
        }
    }

    /** Writes the day's hand-made order: each task's position becomes its rank. */
    suspend fun arrangeDay(orderedTaskIds: List<String>, now: Instant = now()) {
        if (orderedTaskIds.isEmpty()) return
        journalledWrite("Reorder Today") { db ->
            orderedTaskIds.forEachIndexed { rank, taskId ->
                db.task(taskId) ?: fail(WorkspaceStoreError.MISSING_TASK)
                val record = db.metadata(taskId) ?: emptyMetadata(taskId, now)
                if (record.focusRank == rank) return@forEachIndexed
                db.save(record.copy(focusRank = rank, updatedAt = now))
            }
        }
    }

    // endregion

    // region Capture and repeats (WorkspaceStore+Capture.swift, WorkspaceStore+Periodic.swift)

    /** `createTask` for typed text: `45m #work @fri !1` on the end is filed with the task in one undo step. */
    suspend fun createTask(
        capturing: String,
        listId: String,
        parentTaskId: String? = null,
        kanbanColumn: String? = null,
        startAt: Instant? = null,
        atTop: Boolean = false,
        adjacentTaskId: String? = null,
        above: Boolean = false,
        now: Instant = now(),
    ): WorkspaceTask {
        val capture = TaskCapture.parse(capturing, now, zone)
        return createTask(
            listId = listId, title = capture.title, parentTaskId = parentTaskId, kanbanColumn = kanbanColumn,
            startAt = startAt, atTop = atTop, adjacentTaskId = adjacentTaskId, above = above, dueAt = capture.dueAt,
            estimateSeconds = capture.estimateSeconds, tags = capture.tags, priority = capture.priority, now = now,
        )
    }

    /** Whether a task repeats, and how often. */
    suspend fun periodicSchedule(taskId: String): PeriodicSchedule? = database.read { db ->
        db.metadata(taskId)?.recurrenceRule?.let { PeriodicSchedule.parse(it) }
    }

    /** When a task is scheduled to be begun, if anything scheduled it. */
    suspend fun startAt(taskId: String): Instant? = database.read { it.metadata(taskId)?.startAt }

    // endregion

    // region Focus sessions (WorkspaceStore+Focus.swift, WorkspaceStore+Work.swift)

    suspend fun activeFocusSession(): FocusSession? = database.read { activeSession(it) }

    fun observeActiveFocusSession(): Flow<FocusSession?> = database.observe(setOf("focus_sessions")) { activeSession(it) }

    suspend fun focusQueue(sessionId: String): List<FocusQueueTask> = database.read { focusQueue(it, sessionId) }

    fun observeFocusQueue(sessionId: String): Flow<List<FocusQueueTask>> =
        database.observe(setOf("focus_queue_items", "tasks")) { focusQueue(it, sessionId) }

    /** Starts a session on [taskId], or returns the one already running. Not an undo step. */
    suspend fun startFocusSession(
        taskId: String,
        plannedSeconds: Int? = null,
        workDurationSeconds: Int = 25 * 60,
        breakDurationSeconds: Int = 5 * 60,
        context: FocusContext? = null,
        overrideAvailability: Boolean = false,
        now: Instant = now(),
    ): FocusSession = database.write { db ->
        activeSession(db, newestFirst = false)?.let { return@write it }
        validateActionableTask(db, taskId)
        if (context != null && !overrideAvailability) {
            val candidate = focusCandidates(db, now, zone).firstOrNull { it.id == taskId }
            if (candidate == null || TaskAvailabilityPolicy.reasons(candidate, context, now).isNotEmpty()) {
                planningFail(TaskPlanningError.UNAVAILABLE)
            }
            val chosen = plannedSeconds ?: workDurationSeconds
            val window = context.endsAt?.let { secondsBetween(now, it) }
            if (chosen < maxOf(60, candidate.minimumBlockSeconds ?: 60) ||
                (candidate.requiresSingleSitting && chosen < (candidate.remainingSeconds ?: Int.MAX_VALUE)) ||
                (window != null && chosen.toDouble() > window)
            ) {
                planningFail(TaskPlanningError.UNAVAILABLE)
            }
        }
        val session = FocusSession(
            id = newId(), startedAt = now, endedAt = null, phase = FocusSessionPhase.RUNNING, activeTaskId = taskId,
            activeTaskStartedAt = now, workDurationSeconds = maxOf(60, plannedSeconds ?: workDurationSeconds),
            breakDurationSeconds = maxOf(60, breakDurationSeconds), breakEndsAt = null, activeBlockId = newId(),
            accumulatedSeconds = null, pausedAt = null, checkpointAt = now,
        )
        db.insert(session)
        db.insert(
            FocusQueueItem(
                id = newId(), sessionId = session.id, taskId = taskId, sortOrder = 0, state = FocusQueueState.QUEUED,
                plannedSeconds = plannedSeconds, completedAt = null, skippedAt = null, createdAt = now,
            ),
        )
        session
    }

    suspend fun addToFocusQueue(sessionId: String, taskId: String, plannedSeconds: Int? = null, now: Instant = now()) {
        database.write { db ->
            if (db.session(sessionId) == null || db.task(taskId) == null) fail(WorkspaceStoreError.MISSING_TASK)
            validateActionableTask(db, taskId)
            if (db.exists(
                    "SELECT 1 FROM focus_queue_items WHERE sessionId = ? AND taskId = ? AND state = 'queued'",
                    sessionId, taskId,
                )
            ) {
                return@write
            }
            val count = db.int("SELECT COUNT(*) FROM focus_queue_items WHERE sessionId = ?", sessionId) ?: 0
            db.insert(
                FocusQueueItem(
                    id = newId(), sessionId = sessionId, taskId = taskId, sortOrder = count,
                    state = FocusQueueState.QUEUED, plannedSeconds = plannedSeconds, completedAt = null,
                    skippedAt = null, createdAt = now,
                ),
            )
        }
    }

    /**
     * Finishes the current block, crediting [elapsedSeconds]. A daily due today
     * keeps its task open and logs a contribution; otherwise the task completes
     * (when [completeTask]). [qualityMultiplier] scores the block.
     */
    suspend fun completeActiveFocusTask(
        sessionId: String,
        elapsedSeconds: Int = 0,
        qualityMultiplier: Double? = null,
        completeTask: Boolean = true,
        expectedBlockId: String? = null,
        context: FocusContext = FocusContext(),
        now: Instant = now(),
        zone: ZoneId = this.zone,
    ): FocusCompletion = journalledWrite(if (completeTask) "Complete Task" else "Log Daily Progress") { db ->
        completeActiveFocusTask(
            db, sessionId, elapsedSeconds, qualityMultiplier, completeTask, expectedBlockId, context, now, zone,
        )
    }

    suspend fun finishFocusSession(id: String, now: Instant = now()) {
        database.write { db -> finishSession(db, id, now) }
    }

    suspend fun pauseFocusSession(id: String, now: Instant = now()) {
        database.write { db ->
            val session = db.session(id) ?: return@write
            if (session.phase != FocusSessionPhase.RUNNING || session.pausedAt != null) return@write
            db.update(session.copy(accumulatedSeconds = session.elapsedSeconds(now), pausedAt = now, checkpointAt = now))
        }
    }

    suspend fun resumeFocusSession(id: String, now: Instant = now()) {
        database.write { db ->
            val session = db.session(id) ?: return@write
            if (session.phase != FocusSessionPhase.RUNNING || session.pausedAt == null) return@write
            db.update(session.copy(pausedAt = null, activeTaskStartedAt = now, checkpointAt = now))
        }
    }

    suspend fun checkpointFocusSession(id: String, now: Instant = now()) {
        database.write { db ->
            val session = db.session(id) ?: return@write
            if (session.phase != FocusSessionPhase.RUNNING || session.pausedAt != null) return@write
            db.update(
                session.copy(accumulatedSeconds = session.elapsedSeconds(now), activeTaskStartedAt = now, checkpointAt = now),
            )
        }
    }

    /** On reopening, keep only checkpointed seconds; the user resumes the paused block explicitly. */
    suspend fun recoverInterruptedFocus() {
        database.write { db ->
            val running = db.query("SELECT * FROM focus_sessions WHERE phase = 'running'") { it.toSession() }
            for (session in running) {
                if (session.pausedAt != null) continue
                db.update(
                    session.copy(
                        pausedAt = session.checkpointAt ?: session.activeTaskStartedAt,
                        accumulatedSeconds = session.accumulatedSeconds ?: 0,
                    ),
                )
            }
        }
    }

    /** Resumes a queue whose remaining entries were blocked at the last handoff. */
    suspend fun resumeEligibleFocusQueue(context: FocusContext, now: Instant = now()) {
        database.write { db ->
            val session = db.queryOne(
                "SELECT * FROM focus_sessions WHERE phase = 'running' AND activeTaskId IS NULL",
            ) { it.toSession() } ?: return@write
            val candidates = focusCandidates(db, now, zone).associateBy { it.id }
            val queue = db.query(
                "SELECT * FROM focus_queue_items WHERE sessionId = ? AND state = 'queued' ORDER BY sortOrder",
                session.id,
            ) { it.toQueueItem() }
            val next = queue.firstOrNull { item ->
                candidates[item.taskId]?.let { TaskAvailabilityPolicy.reasons(it, context, now).isEmpty() } ?: false
            } ?: return@write
            val task = candidates[next.taskId] ?: return@write
            db.update(
                session.copy(
                    workDurationSeconds = TaskAvailabilityPolicy.plannedSeconds(task, next.plannedSeconds, context, now),
                    activeTaskId = task.id, activeTaskStartedAt = now, activeBlockId = newId(), accumulatedSeconds = 0,
                    pausedAt = null, checkpointAt = now,
                ),
            )
        }
    }

    suspend fun rebaseFocusClock(id: String, elapsedSeconds: Int, now: Instant) {
        database.write { db ->
            val session = db.session(id) ?: return@write
            if (session.phase != FocusSessionPhase.RUNNING || session.pausedAt != null) return@write
            db.update(
                session.copy(accumulatedSeconds = maxOf(0, elapsedSeconds), activeTaskStartedAt = now, checkpointAt = now),
            )
        }
    }

    /** Settles a session left paused on an earlier logical day: closes (crediting) or discards it. */
    suspend fun resolveStaleFocusSession(
        now: Instant = now(),
        boundary: DayBoundary = DayBoundary(zone = zone),
        context: FocusContext = FocusContext(),
    ): StaleFocusResolution {
        val session = activeFocusSession() ?: return StaleFocusResolution.KEEP
        val resolution = StaleFocusPolicy.resolution(
            pausedAt = session.pausedAt, accumulatedSeconds = maxOf(0, session.accumulatedSeconds ?: 0),
            hasActiveTask = session.activeTaskId != null, now = now, boundary = boundary,
        )
        val endedAt = session.pausedAt ?: now
        when (resolution) {
            StaleFocusResolution.KEEP -> Unit
            StaleFocusResolution.CLOSE -> {
                completeActiveFocusTask(
                    sessionId = session.id, elapsedSeconds = maxOf(0, session.accumulatedSeconds ?: 0),
                    completeTask = false, expectedBlockId = session.activeBlockId, context = context, now = endedAt,
                )
                finishFocusSession(session.id, endedAt)
            }
            StaleFocusResolution.DISCARD -> finishFocusSession(session.id, endedAt)
        }
        return resolution
    }

    /** Seconds of focused work per task, across renames and deletions. */
    suspend fun loggedWorkTotals(): Map<String, Int> = database.read { loggedWorkTotals(it) }

    suspend fun workBlocks(taskId: String): List<FocusWorkBlock> = database.read { db ->
        db.query(
            "SELECT * FROM focus_work_blocks WHERE taskId = ? OR originalTaskId = ? ORDER BY recordedAt",
            taskId, taskId,
        ) { it.toWorkBlock() }
    }

    /** Blocks recorded in `[start, end)`. */
    suspend fun focusWorkBlocks(start: Instant, end: Instant): List<FocusWorkBlock> =
        database.read { workBlocksIn(it, start, end) }

    /** When each (non-list) task in `[start, end)` was closed. */
    suspend fun taskCompletions(start: Instant, end: Instant): List<Instant> = database.read { completionsIn(it, start, end) }

    /** When each (non-list) task in `[start, end)` was added. */
    suspend fun taskCreations(start: Instant, end: Instant): List<Instant> = database.read { db ->
        db.query(
            "SELECT createdAt FROM tasks WHERE createdAt >= ? AND createdAt < ? " +
                "AND COALESCE(itemKind, 'task') <> 'list' ORDER BY createdAt",
            start, end,
        ) { it.instant("createdAt") }
    }

    /** Tasks closed since [since], newest first; lists left out, cancellations kept. */
    suspend fun completedTasks(since: Instant, limit: Int = 300): List<WorkspaceTask> = database.read { db ->
        db.query(
            "SELECT * FROM tasks WHERE completedAt IS NOT NULL AND completedAt >= ? " +
                "AND COALESCE(itemKind, 'task') <> 'list' ORDER BY completedAt DESC, id DESC LIMIT ?",
            since, limit,
        ) { it.toTask() }
    }

    /** Today measured against the week it is part of. */
    /** Today against its week; [firstWeekday] (1 = Sunday) is Swift's `Calendar.firstWeekday`. */
    suspend fun workProgress(
        now: Instant = now(),
        zone: ZoneId = this.zone,
        firstWeekday: Int = defaultFirstWeekday(),
    ): WorkProgress = database.read { workProgress(it, now, zone, firstWeekday) }

    fun observeWorkProgress(zone: ZoneId = this.zone): Flow<WorkProgress> =
        database.observe(setOf("tasks", "focus_work_blocks")) { workProgress(it, now(), zone) }

    // endregion

    // region Points (WorkspaceStore+Points.swift)

    /** Most recent first. */
    suspend fun focusAwards(limit: Int = 50): List<FocusAward> = database.read { db ->
        db.query("SELECT * FROM focus_awards ORDER BY awardedAt DESC LIMIT ?", maxOf(0, limit)) { it.toAward() }
    }

    suspend fun focusAwards(onDayOf: Instant, zone: ZoneId = this.zone): List<FocusAward> {
        val day = onDayOf.atZone(zone).toLocalDate()
        return database.read { db ->
            db.query(
                "SELECT * FROM focus_awards WHERE awardedAt >= ? AND awardedAt < ? ORDER BY awardedAt DESC",
                day.atStartOfDay(zone).toInstant(), day.plusDays(1).atStartOfDay(zone).toInstant(),
            ) { it.toAward() }
        }
    }

    /** Today, the trailing seven calendar days, and all time, from one read. */
    suspend fun focusPointsSummary(now: Instant = now(), zone: ZoneId = this.zone): FocusPointsSummary =
        database.read { pointsSummary(it, now, zone) }

    fun observeFocusPointsSummary(zone: ZoneId = this.zone): Flow<FocusPointsSummary> =
        database.observe(setOf("focus_awards")) { pointsSummary(it, now(), zone) }

    // endregion

    // region Search (WorkspaceStore+Search.swift)

    /** Prefix search over titles (weighted 10x) and notes, through FTS5. */
    suspend fun searchTasks(
        workspaceId: String,
        query: String,
        includingCompleted: Boolean = false,
        includingArchivedLists: Boolean = false,
        limit: Int = 60,
    ): List<TaskSearchResult> {
        val trimmed = query.trimmedWhitespace()
        if (trimmed.isEmpty()) return emptyList()
        val pattern = ftsPrefixPattern(trimmed) ?: return emptyList()
        return database.read { db ->
            val conditions = mutableListOf("tasks_fts MATCH ?", "task_lists.workspaceId = ?")
            val args = mutableListOf<Any?>(pattern, workspaceId)
            if (!includingCompleted) {
                conditions += "tasks.status = ?"
                args += TaskStatus.OPEN.raw
            }
            if (!includingArchivedLists) conditions += "task_lists.isArchived = 0"
            args += limit
            val rows = db.query(
                "SELECT tasks.*, task_lists.id AS matchedListId, " +
                    "snippet(tasks_fts, 1, '', '', '…', 10) AS notesSnippet " +
                    "FROM tasks_fts JOIN tasks ON tasks.rowid = tasks_fts.rowid " +
                    "JOIN task_lists ON task_lists.id = tasks.listId " +
                    "WHERE ${conditions.joinToString(" AND ")} ORDER BY bm25(tasks_fts, 10.0, 1.0) LIMIT ?",
                *args.toTypedArray(),
            ) { Triple(it.toTask(), it.string("matchedListId"), it.stringOrNull("notesSnippet")) }
            val lists = HashMap<String, TaskList?>()
            rows.mapNotNull { (task, listId, snippet) ->
                val list = lists.getOrPut(listId) { db.list(listId) } ?: return@mapNotNull null
                TaskSearchResult(task, list, snippet?.trimmedWhitespace()?.takeIf { it.isNotEmpty() })
            }
        }
    }

    // endregion

    // region The day and the ladder (WorkspaceNextUpSnapshot.swift)

    /** Everything the day and the focus ladder are drawn from, in one read. */
    suspend fun nextUpSnapshot(
        workspaceId: String?,
        context: FocusContext,
        runningId: String?,
        now: Instant = now(),
        zone: ZoneId = this.zone,
    ): WorkspaceNextUpSnapshot = database.read { nextUpSnapshot(it, workspaceId, context, runningId, now, zone) }

    /** The snapshot, rebuilt whenever any of the tables behind it change. */
    fun observeNextUpSnapshot(
        workspaceId: String?,
        context: FocusContext,
        runningId: String?,
        zone: ZoneId = this.zone,
    ): Flow<WorkspaceNextUpSnapshot> = database.observe(
        setOf(
            "tasks", "task_lists", "task_metadata", "dailies", "daily_contributions", "focus_work_blocks",
            "task_conditions",
        ),
    ) { nextUpSnapshot(it, workspaceId, context, runningId, now(), zone) }

    // endregion

    // region Counts (for overview screens)

    /** Open and total task counts per list, for a sidebar or a home screen. */
    fun observeTaskCounts(): Flow<TaskCounts> = database.observe(setOf("tasks")) { db ->
        TaskCounts(
            open = db.int("SELECT COUNT(*) FROM tasks WHERE status = 'open' AND COALESCE(itemKind, 'task') <> 'list'") ?: 0,
            completed = db.int(
                "SELECT COUNT(*) FROM tasks WHERE status <> 'open' AND COALESCE(itemKind, 'task') <> 'list'",
            ) ?: 0,
            byList = db.query(
                "SELECT listId, COUNT(*) AS n FROM tasks WHERE status = 'open' GROUP BY listId",
            ) { it.string("listId") to it.int("n") }.toMap(),
        )
    }

    // endregion

    companion object {
        const val JOURNAL_DEPTH = 100

        /** What an undo or redo can change, announced to observers since the core writes on its own connection. */
        private val REPLAYED_TABLES: Set<String> =
            WorkspaceSchema.journalledTables.map { it.first }.toSet() + setOf("change_log", "sync_outbox")

        /** Opens the workspace database at [path] and wraps it. */
        fun open(path: String, clock: Clock = Clock.systemUTC()): WorkspaceRepository =
            WorkspaceRepository(WorkspaceDatabase.open(path), clock)
    }
}

data class HistoryTarget(val taskId: String?, val listId: String?)

data class HistoryEntry(val groupId: String, val label: String?, val isUndone: Boolean, val changeCount: Int)

data class BoardMetadata(val columns: Map<String, String>, val positions: Map<String, TaskMatrixPosition>)

internal fun emptyMetadata(taskId: String, now: Instant) = TaskMetadata(
    taskId = taskId, priority = null, startAt = null, tagsJSON = "[]", recurrenceRule = null, matrixUrgency = null,
    matrixImportance = null, kanbanColumn = null, externalLinksJSON = "[]", focusRank = null, updatedAt = now,
)
