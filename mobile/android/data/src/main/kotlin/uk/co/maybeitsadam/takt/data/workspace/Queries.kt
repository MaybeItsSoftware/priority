package uk.co.maybeitsadam.takt.data.workspace

import java.text.Normalizer
import java.time.Instant
import java.util.Locale
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import uk.co.maybeitsadam.takt.core.ListFolder
import uk.co.maybeitsadam.takt.core.TaskCondition
import uk.co.maybeitsadam.takt.core.TaskList
import uk.co.maybeitsadam.takt.core.TaskListRole
import uk.co.maybeitsadam.takt.core.TaskStatus
import uk.co.maybeitsadam.takt.core.WorkspaceItemKind
import uk.co.maybeitsadam.takt.core.WorkspaceKanbanColumn
import uk.co.maybeitsadam.takt.core.WorkspaceListTree
import uk.co.maybeitsadam.takt.core.WorkspaceTask
import uk.co.maybeitsadam.takt.data.db.Db

// The store's `static func …(_ db: Database, …)` helpers, shared by its methods.

internal fun inbox(db: Db, workspaceId: String): TaskList? = db.core.inbox(workspaceId)?.toList()

internal fun foldersIn(db: Db, workspaceId: String): List<ListFolder> =
    db.core.folders(workspaceId).map { it.toFolder() }

internal fun listsIn(db: Db, workspaceId: String, includingArchived: Boolean): List<TaskList> =
    db.core.lists(workspaceId, includingArchived).map { it.toList() }

internal fun visibleRootParentTaskId(db: Db, listId: String): String? = db.core.visibleRootParent(listId)

internal fun listTree(db: Db, listId: String): WorkspaceListTree =
    WorkspaceListTree(listId, db.core.tasksInLists(listOf(listId)).map { it.toTask() })

/** Several lists' trees from one read: the Rust core's `records::tasks_in_lists`. */
internal fun listTrees(db: Db, listIds: Collection<String>): Map<String, WorkspaceListTree> {
    val grouped = listIds.associateWith { mutableListOf<WorkspaceTask>() }
    for (row in db.core.tasksInLists(listIds.distinct())) grouped[row.listId]?.add(row.toTask())
    return grouped.mapValues { (id, tasks) -> WorkspaceListTree(id, tasks) }
}

internal fun tasksById(db: Db, ids: List<String>): Map<String, WorkspaceTask> =
    db.core.tasksById(ids.distinct()).associate { it.id to it.toTask() }

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
            db.core.tasksInLists(listOf(task.listId)).map { it.toTask() },
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
