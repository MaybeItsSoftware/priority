package uk.co.maybeitsadam.takt.data.workspace

import kotlinx.coroutines.flow.Flow
import uk.co.maybeitsadam.takt.core.ListFolder
import uk.co.maybeitsadam.takt.core.TaskList
import uk.co.maybeitsadam.takt.core.TaskOutlineItem
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

/**
 * The sidebar's raw material: folders, every list (archived too), and what
 * the sidebar draws beneath the active lists.
 *
 * The repository reads [summary] from the Rust core (`sidebar::sidebar_index`),
 * which walks every list there so only the nested lists and the counts cross.
 * It used to read every task of every active list, one list at a time, and
 * walk them here. [trees] is for building one by hand: given trees and no
 * summary, the shaping walks them itself, the same rule the core holds to.
 */
data class SidebarData(
    val folders: List<ListFolder>,
    val lists: List<TaskList>,
    val trees: Map<String, WorkspaceListTree> = emptyMap(),
    val summary: SidebarSummary? = null,
)

/** The nested lists the sidebar draws, with their depth among lists, and each list's and nested list's open count. */
data class SidebarSummary(
    val nestedLists: List<TaskOutlineItem>,
    val openCounts: Map<String, Int>,
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
    val active = lists.filter { !it.isArchived }.map { it.id }
    val summary = if (active.isEmpty()) {
        SidebarSummary(emptyList(), emptyMap())
    } else {
        val index = db.core.sidebarIndexWithOpenCounts(active)
        SidebarSummary(
            nestedLists = index.nestedLists.map { TaskOutlineItem(it.task.toTask(), it.depth.toInt()) },
            openCounts = index.openCounts.associate { it.listId to it.count.toInt() },
        )
    }
    return SidebarData(foldersIn(db, workspaceId), lists, summary = summary)
}

/** The folders and lists tree, re-read when folders, lists or tasks change. */
fun WorkspaceRepository.observeSidebar(workspaceId: String): Flow<SidebarData> =
    database.observe(setOf("tasks", "task_lists", "list_folders")) { readSidebar(it, workspaceId) }

suspend fun WorkspaceRepository.sidebar(workspaceId: String): SidebarData = database.read { readSidebar(it, workspaceId) }
