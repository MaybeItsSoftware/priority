package uk.co.maybeitsadam.priority.ui.lists

import androidx.compose.runtime.Immutable
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.toImmutableList
import uk.co.maybeitsadam.priority.core.SidebarFolderDescriptor
import uk.co.maybeitsadam.priority.core.SidebarListDescriptor
import uk.co.maybeitsadam.priority.core.SidebarNestedListDescriptor
import uk.co.maybeitsadam.priority.core.TaskList
import uk.co.maybeitsadam.priority.core.TaskListRole
import uk.co.maybeitsadam.priority.core.TaskStatus
import uk.co.maybeitsadam.priority.core.WorkspaceListTree
import uk.co.maybeitsadam.priority.core.WorkspaceSidebarIndex
import uk.co.maybeitsadam.priority.core.WorkspaceSidebarOutline
import uk.co.maybeitsadam.priority.core.WorkspaceSidebarRowKind
import uk.co.maybeitsadam.priority.data.workspace.SidebarData

/** One row of the Lists tree, drawn top to bottom in a single lazy column. */
@Immutable
sealed interface TreeRow {
    /** Unique per row; a pinned nested list is drawn twice, so it is not the subject's id. */
    val key: String
    val depth: Int

    @Immutable
    data class Everything(val openCount: Int) : TreeRow {
        override val key = "row:everything"
        override val depth = 0
    }

    @Immutable
    data class ListRow(
        val id: String,
        val name: String,
        override val depth: Int,
        val openCount: Int,
        val isInbox: Boolean,
        val isCompleted: Boolean,
        val folderId: String?,
        val canMoveUp: Boolean,
        val canMoveDown: Boolean,
        override val key: String = "list:$id",
    ) : TreeRow

    /** A list nested inside a task, addressed by the task's id. */
    @Immutable
    data class NestedRow(
        val taskId: String,
        val listId: String,
        val title: String,
        override val depth: Int,
        val openCount: Int,
        val isPinned: Boolean,
        override val key: String,
    ) : TreeRow

    @Immutable
    data class FolderRow(
        val id: String,
        val name: String,
        override val depth: Int,
        val isExpanded: Boolean,
        val parentId: String?,
        val canMoveUp: Boolean,
        val canMoveDown: Boolean,
    ) : TreeRow {
        override val key = "folder:$id"
    }

    @Immutable
    data class ArchivedHeader(val count: Int, val isExpanded: Boolean) : TreeRow {
        override val key = "row:archived"
        override val depth = 0
    }

    @Immutable
    data class ArchivedList(val id: String, val name: String) : TreeRow {
        override val key = "archived:$id"
        override val depth = 1
    }
}

/** A folder for the "Move to folder" pickers: its name with its path depth. */
@Immutable
data class FolderChoice(val id: String, val name: String, val depth: Int)

/** Everything the Lists tree draws, shaped off the main thread. */
@Immutable
data class ListsTreeState(
    val rows: ImmutableList<TreeRow>,
    val folders: ImmutableList<FolderChoice>,
    val isLoaded: Boolean,
) {
    companion object {
        val Empty = ListsTreeState(kotlinx.collections.immutable.persistentListOf(), kotlinx.collections.immutable.persistentListOf(), false)
    }
}

/** Shaping the sidebar data into rows. Pure, so it is tested on the JVM. */
object ListsTreeShaping {
    /**
     * Open, doable tasks per list and per nested list: not lists themselves,
     * not the imported wrapper, nothing beneath a closed or archived nested
     * list. A nested list's count is everything open beneath it.
     */
    fun openCounts(lists: List<TaskList>, trees: Map<String, WorkspaceListTree>): Map<String, Int> {
        val counts = HashMap<String, Int>()
        for (list in lists) {
            val tree = trees[list.id] ?: continue
            val items = tree.outline()
            val inactive = WorkspaceListTree.inactiveContainerItems(items.map { it.task })
            val ancestors = ArrayList<uk.co.maybeitsadam.priority.core.TaskOutlineItem>()
            var listCount = 0
            for (item in items) {
                while (ancestors.isNotEmpty() && ancestors.last().depth >= item.depth) ancestors.removeAt(ancestors.size - 1)
                val task = item.task
                if (!task.isList && task.id != list.visibleRootTaskId && task.status == TaskStatus.OPEN && task.id !in inactive) {
                    listCount++
                    for (ancestor in ancestors) {
                        if (ancestor.task.isList) counts[ancestor.id] = (counts[ancestor.id] ?: 0) + 1
                    }
                }
                ancestors += item
            }
            counts[list.id] = listCount
        }
        return counts
    }

    fun shape(
        data: SidebarData,
        collapsedFolderIds: Set<String>,
        showArchived: Boolean,
    ): ListsTreeState {
        val active = data.lists.filter { !it.isArchived }
        val archived = data.lists.filter { it.isArchived }
        val inbox = active.firstOrNull { it.systemRole == TaskListRole.INBOX }
        val others = active.filter { it.systemRole != TaskListRole.INBOX }
        val counts = openCounts(active, data.trees)
        val index = WorkspaceSidebarIndex.build(active, data.trees)
        val expanded = data.folders.map { it.id }.toSet() - collapsedFolderIds
        val outline = WorkspaceSidebarOutline.rows(
            inbox = inbox?.let { SidebarListDescriptor(it.id, it.folderId) },
            lists = others.map { SidebarListDescriptor(it.id, it.folderId) },
            folders = data.folders.map { SidebarFolderDescriptor(it.id, it.parentFolderId) },
            nestedLists = index.nestedLists.map {
                SidebarNestedListDescriptor(it.id, it.task.listId, it.depth, it.task.isPromoted == true)
            },
            expandedFolderIDs = expanded,
        )
        val listsById = active.associateBy { it.id }
        val foldersById = data.folders.associateBy { it.id }
        val nestedById = index.nestedLists.associateBy { it.id }
        val listSiblings = others.groupBy { it.folderId }
        val folderSiblings = data.folders.groupBy { it.parentFolderId }

        val rows = ArrayList<TreeRow>(outline.size + archived.size + 1)
        for (row in outline) {
            when (val kind = row.kind) {
                WorkspaceSidebarRowKind.Everything ->
                    rows += TreeRow.Everything(active.filter { it.completedAt == null }.sumOf { counts[it.id] ?: 0 })
                is WorkspaceSidebarRowKind.List -> {
                    val list = listsById[kind.id] ?: continue
                    val siblings = listSiblings[list.folderId].orEmpty()
                    val position = siblings.indexOfFirst { it.id == list.id }
                    rows += TreeRow.ListRow(
                        id = list.id, name = list.name, depth = row.depth, openCount = counts[list.id] ?: 0,
                        isInbox = list.systemRole == TaskListRole.INBOX, isCompleted = list.completedAt != null,
                        folderId = list.folderId,
                        canMoveUp = position > 0, canMoveDown = position >= 0 && position < siblings.size - 1,
                    )
                }
                is WorkspaceSidebarRowKind.NestedList -> {
                    val nested = nestedById[kind.id] ?: continue
                    rows += TreeRow.NestedRow(
                        taskId = nested.id, listId = nested.task.listId, title = nested.task.title, depth = row.depth,
                        openCount = counts[nested.id] ?: 0, isPinned = row.id.startsWith("pinned:"), key = row.id,
                    )
                }
                is WorkspaceSidebarRowKind.Folder -> {
                    val folder = foldersById[kind.id] ?: continue
                    val siblings = folderSiblings[folder.parentFolderId].orEmpty()
                    val position = siblings.indexOfFirst { it.id == folder.id }
                    rows += TreeRow.FolderRow(
                        id = folder.id, name = folder.name, depth = row.depth, isExpanded = folder.id in expanded,
                        parentId = folder.parentFolderId,
                        canMoveUp = position > 0, canMoveDown = position >= 0 && position < siblings.size - 1,
                    )
                }
            }
        }
        if (archived.isNotEmpty()) {
            rows += TreeRow.ArchivedHeader(archived.size, showArchived)
            if (showArchived) archived.forEach { rows += TreeRow.ArchivedList(it.id, it.name) }
        }
        return ListsTreeState(rows.toImmutableList(), folderChoices(data), isLoaded = true)
    }

    /** Folders depth-first, so a picker reads like the tree. */
    fun folderChoices(data: SidebarData): ImmutableList<FolderChoice> {
        val children = data.folders.groupBy { it.parentFolderId }
        val result = ArrayList<FolderChoice>()
        val visited = HashSet<String>()
        fun visit(parent: String?, depth: Int) {
            for (folder in children[parent].orEmpty()) {
                if (!visited.add(folder.id)) continue
                result += FolderChoice(folder.id, folder.name, depth)
                visit(folder.id, depth + 1)
            }
        }
        visit(null, 0)
        return result.toImmutableList()
    }
}
