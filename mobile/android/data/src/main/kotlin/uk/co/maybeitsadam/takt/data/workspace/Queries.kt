package uk.co.maybeitsadam.takt.data.workspace

import java.time.Instant
import uk.co.maybeitsadam.takt.core.BoardColumnsRead
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

/** `[WorkspaceKanbanColumn]` as Foundation's JSONEncoder writes it, for seeding a legacy layout. */
internal object KanbanColumnsCodec {
    fun encode(columns: List<WorkspaceKanbanColumn>): String = columns.joinToString(",", "[", "]") {
        "{\"id\":${jsonString(it.id)},\"title\":${jsonString(it.title)}}"
    }
}

/** A stored layout, rules included, read by the Rust core (`parse_board_columns`); empty if it is not one. */
internal fun decodeBoardColumns(json: String): List<WorkspaceKanbanColumn> =
    uniffi.takt_core.parseBoardColumns(json).map { it.toModel() }

/** The tables a board's columns and its rule columns' placements are read from. */
internal val BOARD_TABLES: Set<String> =
    setOf("tasks", "task_dependencies", "task_metadata", "dailies", "task_lists", "kanban_boards")

internal fun uniffi.takt_core.BoardColumn.toModel() = WorkspaceKanbanColumn(id, title, rules)

internal fun WorkspaceKanbanColumn.toCore() = uniffi.takt_core.BoardColumn(id, title, rules)

internal fun uniffi.takt_core.BoardColumns.toRead() = BoardColumnsRead(
    key = key,
    layout = layout.map { it.toModel() },
    source = source,
    columns = columns.map { it.toModel() },
    hiddenColumnIds = hiddenColumnIds.toSet(),
    floorColumnId = floorColumnId,
    // The first placement wins, as on the Mac.
    placements = placements.reversed().associate { it.taskId to it.columnId },
)
