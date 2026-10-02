package uk.co.maybeitsadam.priority.ui.lists

import androidx.compose.runtime.Immutable
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toImmutableList
import uk.co.maybeitsadam.priority.core.MatrixGeometry
import uk.co.maybeitsadam.priority.core.MatrixQuadrant
import uk.co.maybeitsadam.priority.core.TaskMatrixPosition
import uk.co.maybeitsadam.priority.core.TaskOutlineFolding
import uk.co.maybeitsadam.priority.core.TaskStatus
import uk.co.maybeitsadam.priority.core.WorkspaceBoardTrees
import uk.co.maybeitsadam.priority.core.WorkspaceKanbanColumn
import uk.co.maybeitsadam.priority.core.WorkspaceTask
import uk.co.maybeitsadam.priority.data.workspace.ListScopeData

/** One card on the board: its own row, plus its drawn subtasks. */
@Immutable
data class BoardCard(
    val row: OutlineRow,
    /** The list's name, in Everything. */
    val listName: String?,
    /** For a subtask filed in another column than its parent's card: the parent's title. */
    val parentTitle: String?,
    /** Subtask rows after folding; depths from the card's own children (0). */
    val subtasks: ImmutableList<OutlineRow>,
    /** How many subtasks the card has at all, folded or not. */
    val subtaskCount: Int,
) {
    val id: String get() = row.id
}

@Immutable
data class BoardColumnModel(val id: String, val title: String, val cards: ImmutableList<BoardCard>)

@Immutable
data class BoardShape(
    val key: String,
    val columns: ImmutableList<BoardColumnModel>,
    /** Matrix placement for every card. */
    val positions: Map<String, TaskMatrixPosition>,
    val isLoaded: Boolean,
) {
    val columnDefinitions: List<WorkspaceKanbanColumn> get() = columns.map { WorkspaceKanbanColumn(it.id, it.title) }

    fun columnOf(cardId: String): BoardColumnModel? = columns.firstOrNull { c -> c.cards.any { it.id == cardId } }

    companion object {
        val Empty = BoardShape("", persistentListOf(), emptyMap(), false)
    }
}

/** A matrix quadrant as the Mac names and files it: urgency and importance each 0 or 1. */
enum class MatrixCell(val quadrant: MatrixQuadrant, val title: String, val detail: String, val position: TaskMatrixPosition) {
    DO_NOW(MatrixQuadrant.DO_NOW, "Do now", "Urgent and important", TaskMatrixPosition(1, 1)),
    SCHEDULE(MatrixQuadrant.SCHEDULE, "Schedule", "Important, not urgent", TaskMatrixPosition(0, 1)),
    DELEGATE(MatrixQuadrant.DELEGATE, "Delegate", "Urgent, not important", TaskMatrixPosition(1, 0)),
    ELIMINATE(MatrixQuadrant.ELIMINATE, "Eliminate", "Neither", TaskMatrixPosition(0, 0)),
    ;

    companion object {
        /** The quadrant a position falls in, through `MatrixGeometry`; null while either axis is unset. */
        fun of(position: TaskMatrixPosition?): MatrixCell? {
            val urgency = position?.urgency ?: return null
            val importance = position.importance ?: return null
            val quadrant = MatrixGeometry.quadrant(urgency.toDouble(), importance.toDouble())
            return entries.first { it.quadrant == quadrant }
        }
    }
}

@Immutable
data class MatrixQuadrantModel(val cell: MatrixCell, val cards: ImmutableList<BoardCard>)

@Immutable
data class MatrixShape(
    val unplaced: ImmutableList<BoardCard>,
    val quadrants: ImmutableList<MatrixQuadrantModel>,
    val isLoaded: Boolean,
) {
    fun cellOf(cardId: String): MatrixCell? = quadrants.firstOrNull { q -> q.cards.any { it.id == cardId } }?.cell

    companion object {
        val Empty = MatrixShape(persistentListOf(), persistentListOf(), false)
    }
}

/**
 * Port of the iOS `BoardSnapshot.load` and the Mac's `reloadBoardNow`: a
 * list's visible top level are the cards; Everything shows its actionable
 * tasks. A subtask nobody filed follows its parent's column; one filed
 * elsewhere is a card of its own there. Pure; tested on the JVM.
 */
object BoardShaping {
    const val EVERYTHING_KEY = "everything/root"

    /** The `kanban_boards` key the Mac uses for a scope. */
    fun boardKey(listId: String?): String = if (listId == null) EVERYTHING_KEY else "$listId/root"

    fun cardTasks(data: ListScopeData, isEverything: Boolean): List<WorkspaceTask> =
        if (isEverything) {
            data.lists.flatMap { list -> data.trees[list.id]?.actionableTasks(list.visibleRootTaskId).orEmpty() }
        } else {
            data.lists.flatMap { list ->
                val tree = data.trees[list.id] ?: return@flatMap emptyList()
                tree.children(tree.visibleRootParentTaskID(list.visibleRootTaskId))
            }
        }

    /** The scope's own layout, plus any column a card here is filed under that the layout does not list. */
    fun resolvedColumns(
        key: String,
        isEverything: Boolean,
        configurations: Map<String, List<WorkspaceKanbanColumn>>,
        listIds: List<String>,
        usedColumnIds: Set<String>,
    ): List<WorkspaceKanbanColumn> {
        val columns = (configurations[key]?.takeIf { it.isNotEmpty() } ?: WorkspaceKanbanColumn.blitzitDefaults).toMutableList()
        val extras = if (isEverything) {
            listIds.flatMap { configurations["$it/root"].orEmpty() }
        } else {
            configurations[EVERYTHING_KEY].orEmpty() + WorkspaceKanbanColumn.blitzitDefaults
        }
        for (column in extras) {
            if (column.id in usedColumnIds && columns.none { it.id == column.id }) columns += column
        }
        return columns
    }

    fun shape(
        data: ListScopeData,
        isEverything: Boolean,
        configurations: Map<String, List<WorkspaceKanbanColumn>>,
        folded: Set<String>,
        hideCompleted: Boolean,
        zone: ZoneId,
        today: LocalDate,
    ): BoardShape {
        val key = boardKey(if (isEverything) null else data.lists.firstOrNull()?.id)
        val tasks = cardTasks(data, isEverything).filter {
            !((it.isList && it.archivedAt != null) || (hideCompleted && it.status != TaskStatus.OPEN))
        }
        val cardIds = tasks.mapTo(LinkedHashSet()) { it.id }
        val listIds = tasks.map { it.listId }.distinct()
        val board = WorkspaceBoardTrees.build(cardIds, listIds.mapNotNull { data.trees[it] })
        val seen = HashSet<String>()
        val treeTasks = (tasks + tasks.flatMap { t -> board.descendants[t.id].orEmpty().map { it.task } }).filter { seen.add(it.id) }
        val filed = HashMap<String, String>()
        for (task in treeTasks) data.decorations[task.id]?.kanbanColumn?.let { filed[task.id] = it }

        val fallback = WorkspaceKanbanColumn.blitzitDefaults[0].id
        val effective = HashMap<String, String>()
        fun effectiveColumn(task: WorkspaceTask, guard: Int = 0): String {
            effective[task.id]?.let { return it }
            val column = filed[task.id]
                ?: board.parents[task.id]?.takeIf { guard < 512 }?.let { effectiveColumn(it, guard + 1) }
                ?: fallback
            effective[task.id] = column
            return column
        }
        val crossColumn = treeTasks.filter { task ->
            if (hideCompleted && task.status != TaskStatus.OPEN) return@filter false
            if (task.isList || task.id in cardIds) return@filter false
            val parent = board.parents[task.id] ?: return@filter false
            val column = filed[task.id] ?: return@filter false
            column != effectiveColumn(parent)
        }

        val columns = resolvedColumns(key, isEverything, configurations, data.lists.map { it.id }, filed.values.toSet())
        val columnIds = columns.map { it.id }.toSet()
        val firstColumn = columns.firstOrNull()?.id ?: fallback
        val listNames = if (isEverything) data.allLists.associate { it.id to it.name } else emptyMap()
        val byColumn = LinkedHashMap<String, MutableList<BoardCard>>()
        columns.forEach { byColumn[it.id] = ArrayList() }
        val positions = HashMap<String, TaskMatrixPosition>()
        for (task in tasks + crossColumn) {
            val wanted = filed[task.id] ?: fallback
            val column = if (wanted in columnIds) wanted else firstColumn
            val isCross = task.id !in cardIds
            val subtasks = board.descendants[task.id].orEmpty().filter { !hideCompleted || it.task.status == TaskStatus.OPEN }
            val parents = TaskOutlineFolding.parentIDs(subtasks)
            val drawn = if (task.id in folded) emptyList() else TaskOutlineFolding.visible(subtasks, folded)
            val cardHasChildren = subtasks.isNotEmpty()
            val decoration = data.decorations[task.id]
            byColumn.getValue(column) += BoardCard(
                row = OutlineShaping.rowFor(
                    task, 0, decoration, task.id in data.dailyTaskIds, cardHasChildren, task.id in folded, zone, today,
                ),
                listName = listNames[task.listId],
                parentTitle = if (isCross) board.parents[task.id]?.title else null,
                subtasks = drawn.map { OutlineShaping.row(it, data.decorations, data.dailyTaskIds, parents, folded, zone, today) }
                    .toImmutableList(),
                subtaskCount = subtasks.size,
            )
            positions[task.id] = TaskMatrixPosition(decoration?.matrixUrgency, decoration?.matrixImportance)
        }
        return BoardShape(
            key = key,
            columns = columns.map { BoardColumnModel(it.id, it.title, byColumn[it.id].orEmpty().toImmutableList()) }.toImmutableList(),
            positions = positions,
            isLoaded = true,
        )
    }

    /** The matrix over the board's own cards (not subtasks filed in another column). */
    fun matrix(board: BoardShape): MatrixShape {
        val cards = board.columns.flatMap { it.cards }.filter { it.parentTitle == null }
        val byCell = cards.groupBy { MatrixCell.of(board.positions[it.id]) }
        return MatrixShape(
            unplaced = byCell[null].orEmpty().toImmutableList(),
            quadrants = MatrixCell.entries.map { MatrixQuadrantModel(it, byCell[it].orEmpty().toImmutableList()) }.toImmutableList(),
            isLoaded = board.isLoaded,
        )
    }

    /** A column id from a title, unique among [columns]: `waiting-on`, `waiting-on-2`. */
    fun uniqueColumnId(title: String, columns: List<WorkspaceKanbanColumn>): String {
        val base = title.lowercase().replace(Regex("[^a-z0-9]+"), "-").trim('-').ifEmpty { "column" }
        if (columns.none { it.id == base }) return base
        var counter = 2
        while (columns.any { it.id == "$base-$counter" }) counter++
        return "$base-$counter"
    }
}
