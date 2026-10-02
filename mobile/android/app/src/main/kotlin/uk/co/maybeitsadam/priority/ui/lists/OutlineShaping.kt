package uk.co.maybeitsadam.priority.ui.lists

import androidx.compose.runtime.Immutable
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toImmutableList
import uk.co.maybeitsadam.priority.core.NextUpSelector
import uk.co.maybeitsadam.priority.core.TaskList
import uk.co.maybeitsadam.priority.core.TaskOutlineFolding
import uk.co.maybeitsadam.priority.core.TaskOutlineItem
import uk.co.maybeitsadam.priority.core.TaskStatus
import uk.co.maybeitsadam.priority.core.WorkspaceTask
import uk.co.maybeitsadam.priority.data.workspace.ListScopeData
import uk.co.maybeitsadam.priority.data.workspace.TaskDecoration
import uk.co.maybeitsadam.priority.ui.components.Format

/** A due date as a row shows it, with whether it has passed. */
@Immutable
data class DueLabel(val text: String, val isOverdue: Boolean, val isToday: Boolean)

/** One drawn outline row: a value, so a row whose content did not change is not redrawn. */
@Immutable
data class OutlineRow(
    val id: String,
    val listId: String,
    val parentId: String?,
    val title: String,
    val depth: Int,
    val status: TaskStatus,
    val isList: Boolean,
    val hasChildren: Boolean,
    val isFolded: Boolean,
    val due: DueLabel?,
    val estimate: String?,
    val priority: Int?,
    val tags: ImmutableList<String>,
    val isDaily: Boolean,
    val isPlanned: Boolean,
    val hasNotes: Boolean,
)

/** What the outline's lazy column draws: task rows and, in Everything, a header per list. */
@Immutable
sealed interface OutlineEntry {
    val key: String
    val contentType: String

    @Immutable
    data class Header(val listId: String, val name: String, val count: Int) : OutlineEntry {
        override val key = "header:$listId"
        override val contentType = "header"
    }

    @Immutable
    data class Task(val row: OutlineRow) : OutlineEntry {
        override val key = row.id
        override val contentType = "task"
    }
}

/** One list's part of a scope: its rows before folding, and the task they hang from. */
data class OutlineSection(val list: TaskList, val rootParentId: String?, val items: List<TaskOutlineItem>)

/** A scope's outline after folding. [rows] are the task rows alone, in drawn order. */
@Immutable
data class OutlineShape(
    val entries: ImmutableList<OutlineEntry>,
    val rows: ImmutableList<OutlineRow>,
    /** Every row with something beneath it (fold-all folds exactly these). */
    val parentIds: Set<String>,
    val isLoaded: Boolean,
) {
    companion object {
        val Empty = OutlineShape(persistentListOf(), persistentListOf(), emptySet(), false)
    }
}

/** How a drag in the outline lands: before a sibling, or after the last of them. */
sealed interface OutlineDrop {
    data class Before(val targetId: String) : OutlineDrop
    data object ToEnd : OutlineDrop
}

/** The pure half of the outline. Tested on the JVM. */
object OutlineShaping {
    /** The scope's sections: one for a list, one per list for Everything. */
    fun sections(data: ListScopeData): List<OutlineSection> = data.lists.mapNotNull { list ->
        val tree = data.trees[list.id] ?: return@mapNotNull null
        val root = tree.visibleRootParentTaskID(list.visibleRootTaskId)
        OutlineSection(list, root, tree.visibleOutline(root))
    }

    /** Drops every row in [hidden], and everything beneath it. */
    fun withoutBranches(items: List<TaskOutlineItem>, hidden: (TaskOutlineItem) -> Boolean): List<TaskOutlineItem> {
        var hiddenBelow: Int? = null
        return items.filter { item ->
            val depth = hiddenBelow
            if (depth != null) {
                if (item.depth > depth) return@filter false
                hiddenBelow = null
            }
            if (hidden(item)) {
                hiddenBelow = item.depth
                return@filter false
            }
            true
        }
    }

    fun dueLabel(dueAt: Instant, zone: ZoneId, today: LocalDate): DueLabel {
        val local = dueAt.atZone(zone)
        val date = local.toLocalDate()
        val day = Format.day(date, today)
        val text = if (local.hour == 0 && local.minute == 0) day else "$day ${Format.time(dueAt, zone)}"
        return DueLabel(text, isOverdue = date < today, isToday = date == today)
    }

    fun row(
        item: TaskOutlineItem,
        decorations: Map<String, TaskDecoration>,
        dailyIds: Set<String>,
        parents: Set<String>,
        folded: Set<String>,
        zone: ZoneId,
        today: LocalDate,
    ): OutlineRow = rowFor(item.task, item.depth, decorations[item.id], item.id in dailyIds, item.id in parents, item.id in folded, zone, today)

    fun rowFor(
        task: WorkspaceTask,
        depth: Int,
        decoration: TaskDecoration?,
        isDaily: Boolean,
        hasChildren: Boolean,
        isFolded: Boolean,
        zone: ZoneId,
        today: LocalDate,
    ): OutlineRow = OutlineRow(
        id = task.id,
        listId = task.listId,
        parentId = task.parentTaskId,
        title = task.title,
        depth = depth,
        status = task.status,
        isList = task.isList,
        hasChildren = hasChildren,
        isFolded = isFolded && hasChildren,
        due = task.dueAt?.let { dueLabel(it, zone, today) },
        estimate = task.estimateSeconds?.takeIf { it > 0 }?.let { Format.duration(it) },
        priority = decoration?.priority,
        tags = decoration?.tags?.toImmutableList() ?: persistentListOf(),
        isDaily = isDaily,
        isPlanned = decoration?.kanbanColumn == NextUpSelector.todayColumnID,
        hasNotes = task.notes.isNotBlank(),
    )

    /**
     * The drawn outline: closed rows (with their branches) gone when
     * [hideCompleted], [foldedAway] rows gone, folded branches collapsed.
     * Everything gets a header per list that has rows.
     */
    fun shape(
        data: ListScopeData,
        isEverything: Boolean,
        folded: Set<String>,
        hideCompleted: Boolean,
        foldedAway: Set<String>,
        zone: ZoneId,
        today: LocalDate,
    ): OutlineShape {
        val entries = ArrayList<OutlineEntry>()
        val rows = ArrayList<OutlineRow>()
        val allParents = HashSet<String>()
        for (section in sections(data)) {
            val items = withoutBranches(section.items) {
                (hideCompleted && it.task.status != TaskStatus.OPEN) || it.id in foldedAway
            }
            if (items.isEmpty() && isEverything) continue
            val parents = TaskOutlineFolding.parentIDs(items)
            allParents += parents
            if (isEverything) {
                entries += OutlineEntry.Header(
                    section.list.id, section.list.name,
                    items.count { it.task.status == TaskStatus.OPEN && !it.task.isList },
                )
            }
            for (item in TaskOutlineFolding.visible(items, folded)) {
                val row = row(item, data.decorations, data.dailyTaskIds, parents, folded, zone, today)
                rows += row
                entries += OutlineEntry.Task(row)
            }
        }
        return OutlineShape(entries.toImmutableList(), rows.toImmutableList(), allParents, isLoaded = true)
    }

    /** Every folded ancestor of [taskId], read from the unfolded sections. */
    fun ancestors(data: ListScopeData, taskId: String): Set<String> {
        for (section in sections(data)) {
            if (section.items.none { it.id == taskId }) continue
            val result = HashSet<String>()
            var current = TaskOutlineFolding.parentID(taskId, section.items)
            while (current != null && result.add(current)) current = TaskOutlineFolding.parentID(current, section.items)
            return result
        }
        return emptySet()
    }

    /**
     * Where a drag of `rows[from]` (with its drawn subtree) dropped in front of
     * `rows[to]` (or at the end when `to == rows.size`) lands among its
     * siblings. Null when it would not move, or would leave its parent —
     * changing parent is indent/outdent's job.
     */
    fun planDrop(rows: List<OutlineRow>, from: Int, to: Int): OutlineDrop? {
        if (from !in rows.indices) return null
        val moved = rows[from]
        var end = from + 1
        while (end < rows.size && rows[end].depth > moved.depth) end++
        if (to in from..end) return null
        val remaining = rows.subList(0, from) + rows.subList(end, rows.size)
        val adjusted = (if (to > from) to - (end - from) else to).coerceIn(0, remaining.size)
        fun sibling(row: OutlineRow) = row.listId == moved.listId && row.parentId == moved.parentId
        val next = remaining.subList(adjusted, remaining.size).firstOrNull { it.depth <= moved.depth }
        val prev = remaining.subList(0, adjusted).lastOrNull { it.depth <= moved.depth }
        val drop = when {
            next != null && sibling(next) -> OutlineDrop.Before(next.id)
            prev != null && sibling(prev) -> OutlineDrop.ToEnd
            else -> return null
        }
        // Dropping it where it already is.
        val originalNext = rows.subList(end, rows.size).firstOrNull { it.depth <= moved.depth }
        return when (drop) {
            is OutlineDrop.Before -> drop.takeIf { originalNext?.id != drop.targetId }
            OutlineDrop.ToEnd -> drop.takeIf { originalNext != null && sibling(originalNext) }
        }
    }
}
