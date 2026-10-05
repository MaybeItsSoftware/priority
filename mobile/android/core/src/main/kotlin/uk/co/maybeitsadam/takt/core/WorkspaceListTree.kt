package uk.co.maybeitsadam.takt.core

/**
 * One list's tasks, read once and shaped as many ways as a screen needs. Port
 * of the pure half of `WorkspaceListTree.swift`; the store builds it from rows
 * ordered by `sortOrder, createdAt`.
 */
class WorkspaceListTree(
    val listId: String,
    /** Every task in the list, in sibling order (`sortOrder`, then `createdAt`). */
    val tasks: List<WorkspaceTask>,
) {
    private val children: Map<String?, List<WorkspaceTask>> = tasks.groupBy { it.parentTaskId }

    /** Depth-first, in sibling order, starting beneath `parentTaskId`. Cycle-safe. */
    fun outline(under: String? = null): List<TaskOutlineItem> {
        val result = mutableListOf<TaskOutlineItem>()
        val visited = mutableSetOf<String>()
        fun append(parent: String?, depth: Int) {
            for (task in children[parent].orEmpty()) {
                if (!visited.add(task.id)) continue
                result += TaskOutlineItem(task, depth)
                append(task.id, depth + 1)
            }
        }
        append(under, 0)
        return result
    }

    /** The outline without archived nested lists or anything beneath them. */
    fun visibleOutline(under: String? = null): List<TaskOutlineItem> = hidingArchivedLists(outline(under))

    /** A parent's direct children, in sibling order. */
    fun children(of: String?): List<WorkspaceTask> = children[of].orEmpty()

    /** The imported wrapper standing in for the list's roots, while it is the only root. */
    fun visibleRootParentTaskID(registeredRootId: String?): String? {
        if (registeredRootId == null) return null
        val roots = children(null)
        return if (roots.size == 1 && roots.first().id == registeredRootId) registeredRootId else null
    }

    /** The open, doable tasks this list contributes to a combined scope. */
    fun actionableTasks(visibleRootTaskId: String?): List<WorkspaceTask> {
        val items = outline().map { it.task }
        val inactive = inactiveContainerItems(items)
        return items.filter {
            !it.isList && it.id != visibleRootTaskId && it.id !in inactive && it.status == TaskStatus.OPEN
        }
    }

    override fun equals(other: Any?): Boolean = other is WorkspaceListTree && other.listId == listId && other.tasks == tasks
    override fun hashCode(): Int = listId.hashCode() * 31 + tasks.hashCode()

    companion object {
        fun hidingArchivedLists(items: List<TaskOutlineItem>): List<TaskOutlineItem> {
            var archivedDepth: Int? = null
            return items.filter { item ->
                archivedDepth?.let { if (item.depth <= it) archivedDepth = null }
                if (archivedDepth != null) return@filter false
                if (item.task.isList && item.task.archivedAt != null) {
                    archivedDepth = item.depth
                    return@filter false
                }
                true
            }
        }

        /**
         * Port of `WorkspaceStore.inactiveContainerItems`: every nested list that
         * is archived or not open, and everything beneath it.
         */
        fun inactiveContainerItems(tasks: List<WorkspaceTask>): Set<String> {
            val children = tasks.groupBy { it.parentTaskId }
            val result = mutableSetOf<String>()
            fun suppress(task: WorkspaceTask) {
                if (!result.add(task.id)) return
                for (child in children[task.id].orEmpty()) suppress(child)
            }
            for (task in tasks) if (task.isList && (task.archivedAt != null || task.status != TaskStatus.OPEN)) suppress(task)
            return result
        }
    }
}

/** What the sidebar draws beneath its lists: nested lists, archived ones, and task counts. */
data class WorkspaceSidebarIndex(
    val nestedLists: List<TaskOutlineItem>,
    val archivedNestedLists: List<WorkspaceTask>,
    val taskCounts: Map<String, Int>,
) {
    companion object {
        /**
         * Walks each list in order. A nested list's depth counts only the lists
         * above it, and one beneath an archived list is hidden with it.
         */
        fun build(lists: List<TaskList>, trees: Map<String, WorkspaceListTree>): WorkspaceSidebarIndex {
            val nested = mutableListOf<TaskOutlineItem>()
            val archived = mutableListOf<WorkspaceTask>()
            val counts = linkedMapOf<String, Int>()
            for (list in lists) {
                val items = trees[list.id]?.outline().orEmpty()
                counts[list.id] = items.size
                val ancestors = mutableListOf<TaskOutlineItem>()
                for (item in items) {
                    while (ancestors.isNotEmpty() && ancestors.last().depth >= item.depth) ancestors.removeAt(ancestors.size - 1)
                    if (item.task.isList && item.id != list.visibleRootTaskId) {
                        if (item.task.archivedAt != null) archived += item.task
                        if (item.task.archivedAt == null &&
                            ancestors.none { it.task.isList && it.task.archivedAt != null }
                        ) {
                            val depth = ancestors.count { it.task.isList && it.id != list.visibleRootTaskId }
                            nested += TaskOutlineItem(item.task, depth)
                        }
                    }
                    ancestors += item
                }
            }
            return WorkspaceSidebarIndex(nested, archived, counts)
        }
    }
}

/**
 * What a board draws beneath its cards: each card's whole subtree (keyed for
 * every task inside a card's tree too) and every task's parent.
 */
data class WorkspaceBoardTrees(
    /** Depth-first beneath each task, depths from the task's own children (0). */
    val descendants: Map<String, List<TaskOutlineItem>>,
    val parents: Map<String, WorkspaceTask>,
) {
    companion object {
        fun build(cardIDs: Set<String>, trees: List<WorkspaceListTree>): WorkspaceBoardTrees {
            val descendants = LinkedHashMap<String, MutableList<TaskOutlineItem>>()
            for (id in cardIDs) descendants[id] = mutableListOf()
            val parents = linkedMapOf<String, WorkspaceTask>()
            for (tree in trees) {
                val ancestors = mutableListOf<TaskOutlineItem>()
                for (item in tree.visibleOutline()) {
                    while (ancestors.isNotEmpty() && ancestors.last().depth >= item.depth) ancestors.removeAt(ancestors.size - 1)
                    ancestors.lastOrNull()?.let { parents[item.id] = it.task }
                    val insideCard = ancestors.lastOrNull()?.let { descendants.containsKey(it.id) } ?: false
                    if (insideCard) {
                        for (ancestor in ancestors) {
                            descendants[ancestor.id]?.add(TaskOutlineItem(item.task, item.depth - ancestor.depth - 1))
                        }
                    }
                    if (insideCard && !descendants.containsKey(item.id)) descendants[item.id] = mutableListOf()
                    ancestors += item
                }
            }
            return WorkspaceBoardTrees(descendants, parents)
        }
    }
}
