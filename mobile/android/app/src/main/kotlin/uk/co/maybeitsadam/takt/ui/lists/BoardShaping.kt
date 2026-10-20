package uk.co.maybeitsadam.takt.ui.lists

import androidx.compose.runtime.Immutable
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toImmutableList
import uk.co.maybeitsadam.takt.core.BlockedSection
import uk.co.maybeitsadam.takt.core.BoardColumnsRead
import uk.co.maybeitsadam.takt.core.MatrixGeometry
import uk.co.maybeitsadam.takt.core.MatrixQuadrant
import uk.co.maybeitsadam.takt.core.TaskMatrixPosition
import uk.co.maybeitsadam.takt.core.TaskOutlineFolding
import uk.co.maybeitsadam.takt.core.TaskStatus
import uk.co.maybeitsadam.takt.core.WorkspaceBoardTrees
import uk.co.maybeitsadam.takt.core.WorkspaceKanbanColumn
import uk.co.maybeitsadam.takt.core.WorkspaceTask
import uk.co.maybeitsadam.takt.data.workspace.ListScopeData
import uniffi.takt_core.boardColumnId
import uniffi.takt_core.boardCrossColumn
import uniffi.takt_core.matrixArrangement

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
data class BoardColumnModel(
    val id: String,
    val title: String,
    val cards: ImmutableList<BoardCard>,
    /** Filled by its rules rather than by filing: a card dropped here is edited to match. */
    val isRuleColumn: Boolean = false,
) {
    private val sectionLabels: Pair<Set<String>, Set<String>> =
        if (cards.none { it.row.isBlocked || it.row.isBuried }) emptySet<String>() to emptySet()
        else BlockedSection.labelledIds(
            cards.map { it.id to 0 },
            cards.filter { it.row.isBlocked }.mapTo(HashSet()) { it.id },
            cards.filter { it.row.isBuried }.mapTo(HashSet()) { it.id },
        )

    /** The card to draw the "Blocked" label above, if the column ends with blocked cards (they sink to its foot). */
    val blockedLabelId: String? = sectionLabels.first.firstOrNull()

    /** The card to draw the "Buried" label above: buried cards sink below even the blocked ones. */
    val buriedLabelId: String? = sectionLabels.second.firstOrNull()
}

@Immutable
data class BoardShape(
    val key: String,
    val columns: ImmutableList<BoardColumnModel>,
    /** Matrix placement for every card. */
    val positions: Map<String, TaskMatrixPosition>,
    val isLoaded: Boolean,
    /** The layout as an edit saves it, rules and hidden columns included; not the columns drawn. */
    val layout: List<WorkspaceKanbanColumn> = emptyList(),
) {
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
 * elsewhere is a card of its own there. Which columns are drawn, and where a
 * rule column or an entered card's floor puts a card, are the Rust core's
 * ([BoardColumnsRead]). Pure; tested on the JVM.
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

    /**
     * [read] is the core's answer for this scope's board: the columns drawn,
     * and the cards a rule column or an entered card's floor places
     * elsewhere than they are filed. Every other card stands in its filed
     * column when that is drawn, else the first.
     */
    fun shape(
        data: ListScopeData,
        isEverything: Boolean,
        read: BoardColumnsRead,
        folded: Set<String>,
        hideCompleted: Boolean,
        zone: ZoneId,
        today: LocalDate,
    ): BoardShape {
        val key = boardKey(if (isEverything) null else data.lists.firstOrNull()?.id)
        val candidates = cardTasks(data, isEverything).filter {
            !((it.isList && it.archivedAt != null) || (hideCompleted && it.status != TaskStatus.OPEN))
        }
        val candidateIds = candidates.mapTo(LinkedHashSet()) { it.id }
        val listIds = candidates.map { it.listId }.distinct()
        val board = WorkspaceBoardTrees.build(candidateIds, listIds.mapNotNull { data.trees[it] })
        // Everything's cards are open tasks at any depth, and a card draws its
        // subtasks: one beneath another card is drawn there, not again on its
        // own (the core's `board_cards`). Filed in another column, it is still
        // a card of its own there, by the cross-column rule below.
        val tasks = candidates.filterNot { heldByACard(it.id, candidateIds, board.parents) }
        val cardIds = tasks.mapTo(LinkedHashSet()) { it.id }
        val seen = HashSet<String>()
        val treeTasks = (tasks + tasks.flatMap { t -> board.descendants[t.id].orEmpty().map { it.task } }).filter { seen.add(it.id) }
        val filed = HashMap<String, String>()
        for (task in treeTasks) data.decorations[task.id]?.kanbanColumn?.let { filed[task.id] = it }

        val fallback = WorkspaceKanbanColumn.blitzitDefaults[0].id
        // A subtask nobody filed follows its parent's column; one filed
        // elsewhere is a card of its own there: the core's `board_cross_column`,
        // shared with the Mac and iPhone. Rows cross as indices and column codes.
        val codes = HashMap<String, Int>()
        fun code(column: String): Int = codes.getOrPut(column) { codes.size }
        val fallbackCode = code(fallback)
        val rowIndex = HashMap<String, Int>(treeTasks.size * 2)
        treeTasks.forEachIndexed { index, task -> rowIndex[task.id] = index }
        val crossColumn = boardCrossColumn(
            treeTasks.map { task -> board.parents[task.id]?.let { rowIndex[it.id] } ?: -1 },
            treeTasks.map { task -> filed[task.id]?.let(::code) ?: -1 },
            treeTasks.map { task ->
                !(hideCompleted && task.status != TaskStatus.OPEN) && !task.isList && task.id !in cardIds
            },
            fallbackCode,
        ).map { treeTasks[it.toInt()] }

        val columns = read.columns.ifEmpty { WorkspaceKanbanColumn.blitzitDefaults }
        val drawnRead = if (read.columns.isEmpty()) read.copy(columns = columns) else read
        val listNames = if (isEverything) data.allLists.associate { it.id to it.name } else emptyMap()
        val byColumn = LinkedHashMap<String, MutableList<BoardCard>>()
        columns.forEach { byColumn[it.id] = ArrayList() }
        val positions = HashMap<String, TaskMatrixPosition>()
        for (task in tasks + crossColumn) {
            val column = drawnRead.columnId(task.id, filed[task.id]) ?: fallback
            val isCross = task.id !in cardIds
            val subtasks = board.descendants[task.id].orEmpty().filter { !hideCompleted || it.task.status == TaskStatus.OPEN }
            val parents = TaskOutlineFolding.parentIDs(subtasks)
            val drawn = if (task.id in folded) emptyList() else TaskOutlineFolding.visible(subtasks, folded)
            val cardHasChildren = subtasks.isNotEmpty()
            val decoration = data.decorations[task.id]
            byColumn.getValue(column) += BoardCard(
                row = OutlineShaping.rowFor(
                    task, 0, decoration, task.id in data.dailyTaskIds, cardHasChildren, task.id in folded, zone, today,
                    isBlocked = task.id in data.blockedTaskIds,
                    isBuried = task.id in data.buriedTaskIds,
                ),
                listName = listNames[task.listId],
                parentTitle = if (isCross) board.parents[task.id]?.title else null,
                subtasks = drawn.map {
                    OutlineShaping.row(it, data.decorations, data.dailyTaskIds, parents, folded, zone, today, data.blockedTaskIds, data.buriedTaskIds)
                }
                    .toImmutableList(),
                subtaskCount = subtasks.size,
            )
            positions[task.id] = TaskMatrixPosition(decoration?.matrixUrgency, decoration?.matrixImportance, decoration?.matrixRank)
        }
        return BoardShape(
            key = key,
            columns = columns.map {
                BoardColumnModel(it.id, it.title, byColumn[it.id].orEmpty().toImmutableList(), isRuleColumn = it.isRuleColumn)
            }.toImmutableList(),
            positions = positions,
            isLoaded = true,
            layout = read.layout.ifEmpty { columns },
        )
    }

    /** Whether one of [id]'s ancestors is itself a card, and so draws it. */
    internal fun heldByACard(id: String, cardIds: Set<String>, parents: Map<String, WorkspaceTask>): Boolean {
        var at = parents[id]
        // Bounded, so a corrupt cycle ends rather than loops.
        repeat(parents.size + 1) {
            val parent = at ?: return false
            if (parent.id in cardIds) return true
            at = parents[parent.id]
        }
        return false
    }

    /**
     * The matrix over the board's own cards (not subtasks filed in another column). Within a quadrant the
     * cards arranged on the Mac come first, by rank (`v22_matrix_order`), then the rest in board order.
     */
    fun matrix(board: BoardShape): MatrixShape {
        val cards = board.columns.flatMap { it.cards }.filter { it.parentTitle == null }
        // The core's `matrix_arrangement`, shared with the Mac and iPhone.
        val arrangement = matrixArrangement(
            cards.map { board.positions[it.id]?.urgency },
            cards.map { board.positions[it.id]?.importance },
            cards.map { board.positions[it.id]?.rank },
        )
        fun pick(indices: List<UInt>) = indices.map { cards[it.toInt()] }.toImmutableList()
        val order = listOf(MatrixCell.DO_NOW, MatrixCell.SCHEDULE, MatrixCell.DELEGATE, MatrixCell.ELIMINATE)
        val byCell = order.zip(arrangement.quadrants).associate { (cell, indices) -> cell to pick(indices) }
        return MatrixShape(
            unplaced = pick(arrangement.unplaced),
            quadrants = MatrixCell.entries.map { MatrixQuadrantModel(it, byCell[it] ?: persistentListOf()) }.toImmutableList(),
            isLoaded = board.isLoaded,
        )
    }

    /**
     * [layout] with [columnId] titled [title]; a column drawn only because
     * cards are filed in it joins the layout under its new title. Null when
     * nothing changes.
     */
    fun renamingColumn(layout: List<WorkspaceKanbanColumn>, columnId: String, title: String): List<WorkspaceKanbanColumn>? {
        val name = title.trim()
        if (name.isEmpty()) return null
        val updated = if (layout.any { it.id == columnId }) {
            layout.map { if (it.id == columnId) it.copy(title = name) else it }
        } else {
            layout + WorkspaceKanbanColumn(columnId, name)
        }
        return updated.takeUnless { it == layout }
    }

    /**
     * [layout] with [columnId] moved [offset] places past its drawn neighbour
     * in [drawn], as the iPhone's `moveColumn`; null at either end, or when
     * either column is not in the layout.
     */
    fun movingColumn(layout: List<WorkspaceKanbanColumn>, drawn: List<String>, columnId: String, offset: Int): List<WorkspaceKanbanColumn>? {
        val index = drawn.indexOf(columnId)
        if (index < 0) return null
        val neighbourId = drawn.getOrNull(index + offset) ?: return null
        val updated = layout.toMutableList()
        val from = updated.indexOfFirst { it.id == columnId }
        if (from < 0) return null
        val moving = updated.removeAt(from)
        val neighbour = updated.indexOfFirst { it.id == neighbourId }
        if (neighbour < 0) return null
        updated.add(if (offset > 0) neighbour + 1 else neighbour, moving)
        return updated
    }

    /** A column id from a title, unique among [columns]: the core's `board_column_id`. */
    fun uniqueColumnId(title: String, columns: List<WorkspaceKanbanColumn>): String =
        boardColumnId(title, columns.map { it.id })
}
