package uk.co.maybeitsadam.priority.data.workspace

import java.text.Normalizer
import java.time.Instant
import java.util.Locale
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import uk.co.maybeitsadam.priority.core.ListFolder
import uk.co.maybeitsadam.priority.core.TaskCondition
import uk.co.maybeitsadam.priority.core.TaskList
import uk.co.maybeitsadam.priority.core.TaskListRole
import uk.co.maybeitsadam.priority.core.TaskStatus
import uk.co.maybeitsadam.priority.core.WorkspaceItemKind
import uk.co.maybeitsadam.priority.core.WorkspaceKanbanColumn
import uk.co.maybeitsadam.priority.core.WorkspaceListTree
import uk.co.maybeitsadam.priority.core.WorkspaceTask
import uk.co.maybeitsadam.priority.data.db.Db

// The store's `static func …(_ db: Database, …)` helpers, shared by its methods.

internal fun inbox(db: Db, workspaceId: String): TaskList? = db.queryOne(
    "SELECT * FROM task_lists WHERE workspaceId = ? AND systemRole = ?", workspaceId, TaskListRole.INBOX.raw,
) { it.toList() }

/** The Inbox, created (or un-archived) when a workspace lacks one. */
internal fun ensureInbox(db: Db, workspaceId: String, now: Instant): TaskList {
    inbox(db, workspaceId)?.let { existing ->
        if (existing.isArchived) {
            val restored = existing.copy(isArchived = false, updatedAt = now)
            db.update(restored)
            return restored
        }
        return existing
    }
    val order = db.nextOrder("task_lists", "workspaceId = ? AND folderId IS ?", workspaceId, null)
    val inbox = TaskList(
        id = newId(), workspaceId = workspaceId, folderId = null, name = "Inbox", colorHex = null, sortOrder = order,
        isArchived = false, systemRole = TaskListRole.INBOX, visibleRootTaskId = null, completedAt = null,
        createdAt = now, updatedAt = now,
    )
    db.insert(inbox)
    return inbox
}

internal fun seedConditions(db: Db, workspaceId: String, now: Instant) {
    for ((name, location) in listOf("Home" to true, "Campus" to true, "Private" to false, "Floor space" to false)) {
        db.insert(TaskCondition(newId(), workspaceId, name, location, false, now, now))
    }
}

internal fun foldersIn(db: Db, workspaceId: String): List<ListFolder> = db.query(
    "SELECT * FROM list_folders WHERE workspaceId = ? ORDER BY sortOrder, createdAt, id", workspaceId,
) { it.toFolder() }

internal fun listsIn(db: Db, workspaceId: String, includingArchived: Boolean): List<TaskList> = db.query(
    "SELECT * FROM task_lists WHERE workspaceId = ?" + (if (includingArchived) "" else " AND isArchived = 0") +
        " ORDER BY sortOrder, createdAt, id",
    workspaceId,
) { it.toList() }

internal fun listSiblings(db: Db, workspaceId: String, folderId: String?, archived: Boolean): List<TaskList> =
    db.query(
        "SELECT * FROM task_lists WHERE workspaceId = ? AND folderId IS ? AND isArchived = ? " +
            "ORDER BY sortOrder, createdAt, id",
        workspaceId, folderId, archived,
    ) { it.toList() }

internal fun folderSiblings(db: Db, workspaceId: String, parentFolderId: String?): List<ListFolder> = db.query(
    "SELECT * FROM list_folders WHERE workspaceId = ? AND parentFolderId IS ? ORDER BY sortOrder, createdAt, id",
    workspaceId, parentFolderId,
) { it.toFolder() }

internal fun validateFolderParent(db: Db, folder: ListFolder, parentFolderId: String?) {
    if (parentFolderId == folder.id) fail(WorkspaceStoreError.INVALID_FOLDER_MOVE)
    if (parentFolderId != null) {
        val parent = db.folder(parentFolderId)
        if (parent == null || parent.workspaceId != folder.workspaceId) fail(WorkspaceStoreError.MISSING_FOLDER)
        if (parentFolderId in db.folderDescendantIDs(folder.id)) fail(WorkspaceStoreError.INVALID_FOLDER_MOVE)
    }
}

internal fun rootTaskIds(db: Db, listId: String): List<String> =
    db.strings("SELECT id FROM tasks WHERE listId = ? AND parentTaskId IS NULL", listId)

internal fun visibleRootParentTaskId(db: Db, listId: String): String? {
    val rootId = db.list(listId)?.visibleRootTaskId ?: return null
    val roots = rootTaskIds(db, listId)
    return if (roots.size == 1 && roots.first() == rootId) rootId else null
}

internal fun listTree(db: Db, listId: String): WorkspaceListTree = WorkspaceListTree(
    listId,
    db.query("SELECT * FROM tasks WHERE listId = ? ORDER BY sortOrder, createdAt", listId) { it.toTask() },
)

internal fun tasksById(db: Db, ids: List<String>): Map<String, WorkspaceTask> {
    val result = HashMap<String, WorkspaceTask>()
    for (chunk in ids.distinct().chunked(500)) {
        db.query("SELECT * FROM tasks WHERE id IN (${chunk.joinToString(",") { "?" }})", *chunk.toTypedArray()) {
            it.toTask()
        }.forEach { result[it.id] = it }
    }
    return result
}

internal fun actionableTasks(db: Db, workspaceId: String, limitedTo: List<String>?): List<WorkspaceTask> {
    val all = listsIn(db, workspaceId, false).filter { it.completedAt == null }
    val scoped = if (limitedTo != null) {
        val byId = LinkedHashMap<String, TaskList>()
        all.forEach { byId.putIfAbsent(it.id, it) }
        limitedTo.mapNotNull { byId[it] }
    } else {
        all
    }
    val trees = scoped.map { it.id }.toSet().associateWith { listTree(db, it) }
    return scoped.flatMap { list -> trees[list.id]?.actionableTasks(list.visibleRootTaskId) ?: emptyList() }
}

/** Re-files a subtree under another list in one statement, as the Swift store does. */
internal fun moveSubtree(db: Db, ids: Set<String>, listId: String, now: Instant) {
    val sorted = ids.sorted()
    for (chunk in sorted.chunked(500)) {
        db.execute(
            "UPDATE tasks SET listId = ?, updatedAt = ? WHERE id IN (${chunk.joinToString(",") { "?" }})",
            listId, now, *chunk.toTypedArray(),
        )
    }
}

internal fun relocateList(
    db: Db,
    list: TaskList,
    destination: TaskList,
    parentTaskId: String?,
    kind: WorkspaceItemKind,
    now: Instant,
): WorkspaceTask {
    val tasks = db.query("SELECT * FROM tasks WHERE listId = ?", list.id) { it.toTask() }
    val wrapper = tasks.firstOrNull { it.id == list.visibleRootTaskId && it.parentTaskId == null }
    val base = wrapper ?: WorkspaceTask(
        id = newId(), listId = destination.id, parentTaskId = parentTaskId, title = list.name, notes = "",
        status = TaskStatus.OPEN, sortOrder = 0, dueAt = null, estimateSeconds = null, sourceSystem = null,
        sourceId = null, itemKind = null, isPromoted = null, archivedAt = null, completedAt = null,
        createdAt = now, updatedAt = now,
    )
    val root = base.copy(
        listId = destination.id, parentTaskId = parentTaskId, title = list.name, itemKind = kind, isPromoted = null,
        archivedAt = null, status = if (list.completedAt == null) TaskStatus.OPEN else TaskStatus.COMPLETED,
        completedAt = list.completedAt,
        sortOrder = db.nextOrder("tasks", "listId = ? AND parentTaskId IS ?", destination.id, parentTaskId),
        updatedAt = now,
    )
    if (wrapper == null) db.insert(root)
    for (task in tasks) {
        if (task.id == root.id) continue
        db.update(
            task.copy(listId = destination.id, parentTaskId = task.parentTaskId ?: root.id, updatedAt = now),
        )
    }
    if (wrapper != null) db.update(root)
    db.execute("DELETE FROM task_lists WHERE id = ?", list.id)
    return root
}

internal fun upsertKanbanColumn(db: Db, taskId: String, column: String?, now: Instant) {
    db.execute(
        "INSERT INTO task_metadata(taskId, tagsJSON, externalLinksJSON, kanbanColumn, updatedAt) " +
            "VALUES (?, '[]', '[]', ?, ?) ON CONFLICT(taskId) DO UPDATE SET " +
            "kanbanColumn = excluded.kanbanColumn, updatedAt = excluded.updatedAt",
        taskId, column, now,
    )
}

/** Closed or archived containers suppress their descendants without altering their status. */
internal fun validateActionableTask(db: Db, id: String) {
    val task = db.task(id) ?: fail(WorkspaceStoreError.MISSING_TASK)
    val list = db.list(task.listId)
    val ok = !task.isList && list != null && !list.isArchived && list.completedAt == null &&
        list.visibleRootTaskId != id &&
        id !in WorkspaceListTree.inactiveContainerItems(
            db.query("SELECT * FROM tasks WHERE listId = ?", task.listId) { it.toTask() },
        )
    if (!ok) fail(WorkspaceStoreError.INVALID_TASK_MOVE)
}

/** `normalizedVisibleRootName`: case- and diacritic-folded, letters and digits only. */
internal fun normalizedVisibleRootName(name: String): String {
    val folded = Normalizer.normalize(name.lowercase(Locale.getDefault()), Normalizer.Form.NFD)
        .replace(Regex("\\p{M}+"), "")
    return folded.trimmedWhitespace().replace(Regex("[^\\p{L}\\p{N}]+"), "")
}

/** `[WorkspaceKanbanColumn]` as Foundation's JSONEncoder writes it. */
internal object KanbanColumnsCodec {
    fun encode(columns: List<WorkspaceKanbanColumn>): String = columns.joinToString(",", "[", "]") {
        "{\"id\":${jsonString(it.id)},\"title\":${jsonString(it.title)}}"
    }

    fun decode(json: String): List<WorkspaceKanbanColumn>? = runCatching {
        (Json.parseToJsonElement(json) as JsonArray).map { element ->
            val obj = element as JsonObject
            WorkspaceKanbanColumn(obj["id"]!!.jsonPrimitive.content, obj["title"]!!.jsonPrimitive.content)
        }
    }.getOrNull()
}
