package uk.co.maybeitsadam.priority.core

/** What a sidebar row is. */
sealed interface WorkspaceSidebarRowKind {
    data object Everything : WorkspaceSidebarRowKind
    data class List(val id: String) : WorkspaceSidebarRowKind
    /** A list nested inside a task, addressed by the task's id. */
    data class NestedList(val id: String) : WorkspaceSidebarRowKind
    data class Folder(val id: String) : WorkspaceSidebarRowKind
}

data class WorkspaceSidebarRow(
    /** Unique per row, not per thing: a pinned nested list is drawn twice. */
    val id: String,
    val kind: WorkspaceSidebarRowKind,
    /** Indentation; zero for the top-level rows. */
    val depth: Int,
) {
    /** The thing this row points at, which two rows can share. */
    val subjectID: String?
        get() = when (kind) {
            WorkspaceSidebarRowKind.Everything -> null
            is WorkspaceSidebarRowKind.List -> kind.id
            is WorkspaceSidebarRowKind.NestedList -> kind.id
            is WorkspaceSidebarRowKind.Folder -> kind.id
        }
}

data class SidebarListDescriptor(val id: String, val folderID: String?)

data class SidebarNestedListDescriptor(
    /** The task's id: a nested list is a task. */
    val id: String,
    val listID: String,
    val depth: Int,
    val isPromoted: Boolean,
)

data class SidebarFolderDescriptor(val id: String, val parentFolderID: String?)

/** The sidebar, top to bottom, as one list. Port of `WorkspaceSidebarOutline.swift`. */
object WorkspaceSidebarOutline {
    fun rows(
        inbox: SidebarListDescriptor?,
        lists: List<SidebarListDescriptor>,
        folders: List<SidebarFolderDescriptor>,
        nestedLists: List<SidebarNestedListDescriptor>,
        expandedFolderIDs: Set<String>,
    ): List<WorkspaceSidebarRow> {
        val result = mutableListOf(WorkspaceSidebarRow("row:everything", WorkspaceSidebarRowKind.Everything, 0))
        val visitedFolders = mutableSetOf<String>()

        fun appendList(list: SidebarListDescriptor, depth: Int) {
            result += WorkspaceSidebarRow("list:${list.id}", WorkspaceSidebarRowKind.List(list.id), depth)
            for (nested in nestedLists) if (nested.listID == list.id) {
                result += WorkspaceSidebarRow(
                    "nested:${list.id}:${nested.id}",
                    WorkspaceSidebarRowKind.NestedList(nested.id),
                    depth + 1 + nested.depth,
                )
            }
        }

        fun appendFolder(folder: SidebarFolderDescriptor, depth: Int) {
            if (!visitedFolders.add(folder.id)) return
            result += WorkspaceSidebarRow("folder:${folder.id}", WorkspaceSidebarRowKind.Folder(folder.id), depth)
            if (folder.id !in expandedFolderIDs) return
            for (list in lists) if (list.folderID == folder.id) appendList(list, depth + 1)
            for (child in folders) if (child.parentFolderID == folder.id) appendFolder(child, depth + 1)
        }

        inbox?.let { appendList(it, 0) }
        for (nested in nestedLists) if (nested.isPromoted) {
            result += WorkspaceSidebarRow("pinned:${nested.id}", WorkspaceSidebarRowKind.NestedList(nested.id), 0)
        }
        for (folder in folders) if (folder.parentFolderID == null) appendFolder(folder, 0)
        for (list in lists) if (list.folderID == null) appendList(list, 0)
        return result
    }

    /** The row `offset` steps from `id`, stopping at either end rather than wrapping. */
    fun row(after: String?, by: Int, rows: List<WorkspaceSidebarRow>): WorkspaceSidebarRow? {
        if (rows.isEmpty()) return null
        val index = if (after == null) -1 else rows.indexOfFirst { it.id == after }
        if (index < 0) return if (by < 0) rows.last() else rows.first()
        return rows[(index + by).coerceIn(0, rows.size - 1)]
    }

    /** The row matching what the workspace has selected. */
    fun rowMatching(subjectID: String?, isEverything: Boolean, rows: List<WorkspaceSidebarRow>): WorkspaceSidebarRow? {
        if (isEverything) return rows.firstOrNull { it.kind == WorkspaceSidebarRowKind.Everything }
        if (subjectID == null) return null
        return rows.firstOrNull { it.subjectID == subjectID }
    }

    /** Every list inside a folder, including its sub-folders', this folder's own first. Cycle-safe. */
    fun listIDs(
        inFolder: String,
        folders: List<SidebarFolderDescriptor>,
        lists: List<SidebarListDescriptor>,
    ): List<String> {
        val visited = mutableSetOf<String>()
        val result = mutableListOf<String>()
        fun descend(id: String) {
            if (!visited.add(id)) return
            result += lists.filter { it.folderID == id }.map { it.id }
            for (child in folders) if (child.parentFolderID == id) descend(child.id)
        }
        descend(inFolder)
        return result
    }
}
