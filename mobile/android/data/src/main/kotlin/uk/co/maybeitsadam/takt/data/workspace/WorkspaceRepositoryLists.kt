package uk.co.maybeitsadam.takt.data.workspace

import kotlinx.coroutines.flow.Flow
import uk.co.maybeitsadam.takt.core.ListFolder
import uk.co.maybeitsadam.takt.core.TaskList
import uk.co.maybeitsadam.takt.core.WorkspaceListTree
import uk.co.maybeitsadam.takt.data.db.Db

// Reads for the Android Lists screens: the tree of folders and lists, and one
// scope's tasks with everything a row draws beside its title, each in one read
// transaction so a screen sees one moment.

/** What a row draws beside a task's title, from its `task_metadata` row. */
data class TaskDecoration(
    val priority: Int? = null,
    val tags: List<String> = emptyList(),
    val kanbanColumn: String? = null,
    val matrixUrgency: Int? = null,
    val matrixImportance: Int? = null,
    /** Who or what it waits on, while it is in `waiting-on`. */
    val waitingOn: String? = null,
    /** When to chase it. */
    val followUpAt: java.time.Instant? = null,
)

/** One list scope, read at once: its lists, their trees, and the rows' decorations. */
data class ListScopeData(
    /** The lists in scope, in sidebar order: one for a list, every active list for Everything. */
    val lists: List<TaskList>,
    val trees: Map<String, WorkspaceListTree>,
    /** By task id; a task without metadata is absent. */
    val decorations: Map<String, TaskDecoration>,
    /** Tasks with an active (unarchived) daily. */
    val dailyTaskIds: Set<String>,
    /** Every unarchived list in the workspace, for pickers. */
    val allLists: List<TaskList>,
)

/** The sidebar's raw material: folders, every list (archived too), and the active lists' trees. */
data class SidebarData(
    val folders: List<ListFolder>,
    val lists: List<TaskList>,
    val trees: Map<String, WorkspaceListTree>,
)

private fun Db.decorations(listIds: Collection<String>): Map<String, TaskDecoration> {
    val result = HashMap<String, TaskDecoration>()
    for (chunk in listIds.toList().chunked(500)) {
        if (chunk.isEmpty()) continue
        query(
            "SELECT m.* FROM task_metadata m JOIN tasks t ON t.id = m.taskId " +
                "WHERE t.listId IN (${chunk.joinToString(",") { "?" }})",
            *chunk.toTypedArray(),
        ) { it.toMetadata() }.forEach { m ->
            result[m.taskId] = TaskDecoration(
                priority = m.priority,
                tags = decodeStringArray(m.tagsJSON),
                kanbanColumn = m.kanbanColumn,
                matrixUrgency = m.matrixUrgency,
                matrixImportance = m.matrixImportance,
                waitingOn = m.waitingOn,
                followUpAt = m.waitingFollowUpAt,
            )
        }
    }
    return result
}

private fun Db.activeDailyTaskIds(): Set<String> =
    strings("SELECT taskId FROM dailies WHERE archivedAt IS NULL").toSet()

internal fun readListScope(db: Db, workspaceId: String, listId: String?): ListScopeData {
    val all = listsIn(db, workspaceId, false)
    val lists = if (listId == null) {
        all.filter { it.completedAt == null }
    } else {
        listOfNotNull(db.list(listId))
    }
    val trees = lists.associate { it.id to listTree(db, it.id) }
    return ListScopeData(
        lists = lists,
        trees = trees,
        decorations = db.decorations(trees.keys),
        dailyTaskIds = db.activeDailyTaskIds(),
        allLists = all,
    )
}

/**
 * One list (or, with a null [listId], the Everything scope: every open,
 * unarchived list) with its tasks and their decorations, re-read whenever a
 * write touches tasks, their metadata, dailies or lists.
 */
fun WorkspaceRepository.observeListScope(workspaceId: String, listId: String?): Flow<ListScopeData> =
    database.observe(setOf("tasks", "task_metadata", "dailies", "task_lists")) { readListScope(it, workspaceId, listId) }

suspend fun WorkspaceRepository.listScope(workspaceId: String, listId: String?): ListScopeData =
    database.read { readListScope(it, workspaceId, listId) }

internal fun readSidebar(db: Db, workspaceId: String): SidebarData {
    val lists = listsIn(db, workspaceId, true)
    val trees = lists.filter { !it.isArchived }.associate { it.id to listTree(db, it.id) }
    return SidebarData(foldersIn(db, workspaceId), lists, trees)
}

/** The folders and lists tree, re-read when folders, lists or tasks change. */
fun WorkspaceRepository.observeSidebar(workspaceId: String): Flow<SidebarData> =
    database.observe(setOf("tasks", "task_lists", "list_folders")) { readSidebar(it, workspaceId) }

suspend fun WorkspaceRepository.sidebar(workspaceId: String): SidebarData = database.read { readSidebar(it, workspaceId) }
