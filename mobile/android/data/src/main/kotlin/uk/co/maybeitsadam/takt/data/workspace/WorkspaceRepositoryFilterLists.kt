package uk.co.maybeitsadam.takt.data.workspace

import java.time.Instant
import kotlinx.coroutines.flow.Flow
import uk.co.maybeitsadam.takt.core.TaskList
import uk.co.maybeitsadam.takt.core.WorkspaceTask
import uk.co.maybeitsadam.takt.data.db.Db
import uniffi.takt_core.FilterDefinition
import uniffi.takt_core.FilterListRow
import uniffi.takt_core.describeFilterDefinition

// Filter lists: saved, named rule sets over every task. Which tasks one shows
// is the Rust core's question (`filter_lists`), asked the same way on every
// client; here are the reads a screen draws from, and the writes as undoable
// steps. Today and Everything are built in (`builtin:today`,
// `builtin:everything`) and have no row; the phone draws them as its own
// places, so [filterLists] is only the user's.

/** A filter list as a screen shows it. */
data class FilterList(
    val id: String,
    val workspaceId: String,
    val name: String,
    /** An SF Symbol name; the phone draws its own icon. */
    val icon: String?,
    val colorHex: String?,
    val definition: FilterDefinition,
    /** The definition in words, the core's: "Open tasks where tag has work". */
    val summary: String,
    val sortOrder: Long,
    val isBuiltin: Boolean,
)

/** One task a filter list shows, with the list it lives in. */
data class FilterListMatch(val task: WorkspaceTask, val list: TaskList)

/** What a filter list's screen draws: the list (null once it is deleted) and its matches in board order. */
data class FilterListScope(
    val filterList: FilterList?,
    val matches: List<FilterListMatch> = emptyList(),
    /** Matches waiting on an open task, drawn greyed. */
    val blockedTaskIds: Set<String> = emptySet(),
)

/**
 * The tables a filter list's matches depend on: its rules read tasks, their
 * metadata (tags, priority, planning, waiting), dependencies (blocked), lists
 * and folders. Rules about the clock ("due today") are re-read with them,
 * not on a timer.
 */
internal val FILTER_LIST_TABLES: Set<String> =
    setOf("filter_lists", "tasks", "task_metadata", "task_dependencies", "task_lists", "list_folders")

internal fun FilterListRow.toFilterList() = FilterList(
    id = id,
    workspaceId = workspaceId,
    name = name,
    icon = icon,
    colorHex = colorHex,
    definition = definition,
    summary = describeFilterDefinition(definition),
    sortOrder = sortOrder,
    isBuiltin = isBuiltin,
)

/** The workspace's own filter lists, in sidebar order. */
suspend fun WorkspaceRepository.filterLists(workspaceId: String): List<FilterList> =
    database.read { db -> db.core.filterLists(workspaceId).map { it.toFilterList() } }

/** [filterLists], re-read when one is created, edited, moved or deleted (here or by sync). */
fun WorkspaceRepository.observeFilterLists(workspaceId: String): Flow<List<FilterList>> =
    database.observe(setOf("filter_lists")) { db -> db.core.filterLists(workspaceId).map { it.toFilterList() } }

/** One filter list, stored or built in; null when there is none. */
suspend fun WorkspaceRepository.filterList(id: String): FilterList? =
    coreRead { it.filterList(id)?.toFilterList() }

/**
 * The tasks filter list [id] shows across [workspaceId], in board order: list
 * by list, each in outline order. Fails with
 * [WorkspaceStoreError.MISSING_FILTER_LIST] when there is no such list.
 */
suspend fun WorkspaceRepository.filterListTasks(workspaceId: String, id: String, now: Instant = now()): List<WorkspaceTask> {
    val definition = coreRead { it.filterList(id) }?.definition ?: fail(WorkspaceStoreError.MISSING_FILTER_LIST)
    return filterListTasks(workspaceId, definition, now)
}

/** The tasks [definition] shows across [workspaceId], in board order. */
suspend fun WorkspaceRepository.filterListTasks(
    workspaceId: String,
    definition: FilterDefinition,
    now: Instant = now(),
): List<WorkspaceTask> = coreRead { core ->
    core.filterListTasks(workspaceId, definition, now.toEpochMilli(), zone.id).map { it.toTask() }
}

suspend fun WorkspaceRepository.filterListScope(workspaceId: String, id: String): FilterListScope =
    database.read { filterListScope(it, workspaceId, id, now()) }

/** [filterListScope], re-read whenever anything its rules read changes. */
fun WorkspaceRepository.observeFilterListScope(workspaceId: String, id: String): Flow<FilterListScope> =
    database.observe(FILTER_LIST_TABLES) { filterListScope(it, workspaceId, id, now()) }

private fun WorkspaceRepository.filterListScope(db: Db, workspaceId: String, id: String, now: Instant): FilterListScope {
    val filterList = db.core.filterList(id)?.toFilterList() ?: return FilterListScope(null)
    val tasks = db.core.filterListTasks(workspaceId, filterList.definition, now.toEpochMilli(), zone.id).map { it.toTask() }
    val lists = listsIn(db, workspaceId, includingArchived = true).associateBy { it.id }
    val blocked = db.core.blockedTaskIds().toSet()
    return FilterListScope(
        filterList = filterList,
        matches = tasks.mapNotNull { task -> lists[task.listId]?.let { FilterListMatch(task, it) } },
        blockedTaskIds = tasks.mapNotNullTo(HashSet()) { task -> task.id.takeIf { it in blocked } },
    )
}

/**
 * Creates a filter list at the end of the workspace's as one "New Filter
 * List" step. A rule the core does not know fails with
 * [WorkspaceStoreError.INVALID_FILTER]; an empty name with
 * [WorkspaceStoreError.EMPTY_NAME].
 */
suspend fun WorkspaceRepository.createFilterList(
    workspaceId: String,
    name: String,
    definition: FilterDefinition,
    icon: String? = null,
    colorHex: String? = null,
    now: Instant = now(),
): FilterList = coreWrite { it.createFilterList(workspaceId, name, icon, colorHex, definition, now.toEpochMilli()) }.toFilterList()

/** Saves a filter list's name, icon, colour and rules as one "Edit Filter List" step. */
suspend fun WorkspaceRepository.updateFilterList(
    id: String,
    name: String,
    definition: FilterDefinition,
    icon: String? = null,
    colorHex: String? = null,
    now: Instant = now(),
): FilterList = coreWrite { it.updateFilterList(id, name, icon, colorHex, definition, now.toEpochMilli()) }.toFilterList()

suspend fun WorkspaceRepository.renameFilterList(id: String, name: String, now: Instant = now()) =
    coreWrite { it.renameFilterList(id, name, now.toEpochMilli()) }

suspend fun WorkspaceRepository.deleteFilterList(id: String) = coreWrite { it.deleteFilterList(id) }

/** Moves a filter list to [index] among the workspace's as one "Move Filter List" step. */
suspend fun WorkspaceRepository.moveFilterList(id: String, index: Int, now: Instant = now()) =
    coreWrite { it.moveFilterList(id, index.coerceAtLeast(0).toUInt(), now.toEpochMilli()) }
