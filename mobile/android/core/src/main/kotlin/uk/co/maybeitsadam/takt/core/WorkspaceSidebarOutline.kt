package uk.co.maybeitsadam.takt.core

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
        // The Rust core's order (`sidebar::outline`), as the Mac's. The phone
        // has no Today place in its tree (Today is a tab), so it asks without
        // one. Rows cross back as a kind and an index into what was passed.
        val rows = uniffi.takt_core.sidebarOutlineRows(
            inbox?.id, lists.map { it.core }, folders.map { it.core }, nestedLists.map { it.core },
            expandedFolderIDs.toList(), false,
        )
        return rows.mapNotNull { row ->
            val index = row.subject.toInt()
            val depth = row.depth.toInt()
            when (row.kind) {
                uniffi.takt_core.SidebarRowKind.TODAY -> null
                uniffi.takt_core.SidebarRowKind.EVERYTHING ->
                    WorkspaceSidebarRow("row:everything", WorkspaceSidebarRowKind.Everything, depth)
                uniffi.takt_core.SidebarRowKind.INBOX -> inbox?.let {
                    WorkspaceSidebarRow("list:${it.id}", WorkspaceSidebarRowKind.List(it.id), depth)
                }
                uniffi.takt_core.SidebarRowKind.LIST -> lists[index].id.let {
                    WorkspaceSidebarRow("list:$it", WorkspaceSidebarRowKind.List(it), depth)
                }
                uniffi.takt_core.SidebarRowKind.NESTED_LIST -> nestedLists[index].let {
                    WorkspaceSidebarRow("nested:${it.listID}:${it.id}", WorkspaceSidebarRowKind.NestedList(it.id), depth)
                }
                uniffi.takt_core.SidebarRowKind.PINNED_NESTED_LIST -> nestedLists[index].id.let {
                    WorkspaceSidebarRow("pinned:$it", WorkspaceSidebarRowKind.NestedList(it), depth)
                }
                uniffi.takt_core.SidebarRowKind.FOLDER -> folders[index].id.let {
                    WorkspaceSidebarRow("folder:$it", WorkspaceSidebarRowKind.Folder(it), depth)
                }
            }
        }
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
    ): List<String> = uniffi.takt_core.sidebarListIdsInFolder(inFolder, folders.map { it.core }, lists.map { it.core })
}

private val SidebarListDescriptor.core get() = uniffi.takt_core.SidebarList(id, folderID)
private val SidebarFolderDescriptor.core get() = uniffi.takt_core.SidebarFolder(id, parentFolderID)
private val SidebarNestedListDescriptor.core
    get() = uniffi.takt_core.SidebarNestedList(id, listID, depth.coerceAtLeast(0).toUInt(), isPromoted)
