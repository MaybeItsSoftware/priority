package uk.co.maybeitsadam.takt.ui.lists

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import uk.co.maybeitsadam.takt.app.AppContainer
import uk.co.maybeitsadam.takt.app.CelebrationStyle
import uk.co.maybeitsadam.takt.app.FoldStore
import uk.co.maybeitsadam.takt.core.TaskList
import uk.co.maybeitsadam.takt.core.TaskMatrixPosition
import uk.co.maybeitsadam.takt.core.TaskStatus
import uk.co.maybeitsadam.takt.core.WorkspaceKanbanColumn
import uk.co.maybeitsadam.takt.core.WorkspaceTask
import uk.co.maybeitsadam.takt.data.workspace.ListScopeData
import uk.co.maybeitsadam.takt.data.workspace.observeListScope

/** The three ways a list is drawn, as the Mac's Ctrl+2/3/4 switch them. */
enum class ListViewMode(val raw: String, val title: String) {
    OUTLINE("outline", "Outline"),
    BOARD("board", "Board"),
    MATRIX("matrix", "Matrix"),
    ;

    companion object {
        fun of(raw: String?): ListViewMode = entries.firstOrNull { it.raw == raw } ?: OUTLINE
    }
}

/** A scope's data with its tasks indexed by id, built off the main thread. */
class ScopeSnapshot(val data: ListScopeData, val tasks: Map<String, WorkspaceTask>)

/**
 * One list scope (a list, or Everything when [listId] is null): its outline,
 * board and matrix, all shaped off the main thread from one observed read,
 * and every edit made there.
 */
class ListViewModel(
    private val container: AppContainer,
    val listId: String?,
    revealTaskId: String?,
) : ViewModel() {
    val isEverything: Boolean get() = listId == null
    private val foldKey = listId ?: FoldStore.EVERYTHING
    private val boardKey = BoardShaping.boardKey(listId)
    private val viewKey = "listView.${listId ?: "everything"}"
    private val commands get() = container.commands
    private val undo get() = container.undo

    private val snapshot: StateFlow<ScopeSnapshot?> = container.withSession { session ->
        session.repository.observeListScope(session.workspace.id, listId)
    }.map { data ->
        val tasks = HashMap<String, WorkspaceTask>()
        for (tree in data.trees.values) for (task in tree.tasks) tasks[task.id] = task
        ScopeSnapshot(data, tasks)
    }.flowOn(Dispatchers.Default)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    private val folded: Flow<Set<String>> = container.folds.folded(foldKey)

    val hideCompleted: StateFlow<Boolean> = container.settings.string(HIDE_COMPLETED).map { it == "true" }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), false)

    val celebration: StateFlow<CelebrationStyle> = container.settings.celebrationStyle
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), CelebrationStyle.STRIKE)

    val viewMode: StateFlow<ListViewMode> = container.settings.string(viewKey).map { ListViewMode.of(it) }
        .stateIn(viewModelScope, SharingStarted.Eagerly, ListViewMode.OUTLINE)

    /** Rows the Fold celebration has folded away this visit. */
    private val foldedAway = MutableStateFlow<Set<String>>(emptySet())

    private val _selectedId = MutableStateFlow<String?>(null)
    val selectedId: StateFlow<String?> = _selectedId.asStateFlow()

    /** A row to scroll to once it is drawn; consumed by the outline. */
    private val _scrollTo = MutableStateFlow<String?>(null)
    val scrollTo: StateFlow<String?> = _scrollTo.asStateFlow()

    val list: StateFlow<TaskList?> = snapshot.map { s -> if (listId == null) null else s?.data?.lists?.firstOrNull() }
        .distinctUntilChanged()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    /** Every unarchived list, for the move-to-list picker. */
    val allLists: StateFlow<List<TaskList>> = snapshot.map { it?.data?.allLists.orEmpty() }.distinctUntilChanged()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    val outline: StateFlow<OutlineShape> = combine(snapshot.filterNotNull(), folded, hideCompleted, foldedAway) { s, f, h, away ->
        OutlineShaping.shape(s.data, isEverything, f, h, away, ZoneId.systemDefault(), LocalDate.now())
    }.flowOn(Dispatchers.Default)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), OutlineShape.Empty)

    private val boards: Flow<Map<String, List<WorkspaceKanbanColumn>>> = container.withSession { session ->
        flow {
            // Seeds the defaults for a scope without a layout, as the Mac does, without an undo step.
            runCatching { session.repository.kanbanBoardConfigurations(currentKey = boardKey) }
            emitAll(session.repository.observeKanbanBoards())
        }
    }

    val board: StateFlow<BoardShape> = combine(snapshot.filterNotNull(), boards, folded, hideCompleted) { s, b, f, h ->
        BoardShaping.shape(s.data, isEverything, b, f, h, ZoneId.systemDefault(), LocalDate.now())
    }.flowOn(Dispatchers.Default)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), BoardShape.Empty)

    val matrix: StateFlow<MatrixShape> = board.map { BoardShaping.matrix(it) }.flowOn(Dispatchers.Default)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), MatrixShape.Empty)

    init {
        if (revealTaskId != null) reveal(revealTaskId)
    }

    fun task(id: String): WorkspaceTask? = snapshot.value?.tasks?.get(id)

    // region Selection and folding

    fun select(id: String?) {
        _selectedId.value = id
    }

    /** Selects the row [by] steps from the selection, over [rows]. */
    fun selectAdjacent(rows: List<OutlineRow>, by: Int) {
        if (rows.isEmpty()) return
        val index = rows.indexOfFirst { it.id == _selectedId.value }
        val next = if (index < 0) (if (by > 0) 0 else rows.size - 1) else (index + by).coerceIn(0, rows.size - 1)
        _selectedId.value = rows[next].id
        _scrollTo.value = rows[next].id
    }

    fun consumeScroll() {
        _scrollTo.value = null
    }

    /** Unfolds [taskId]'s ancestors, then selects it and asks the outline to scroll to it. */
    fun reveal(taskId: String) {
        viewModelScope.launch {
            val data = snapshot.filterNotNull().first().data
            val ancestors = OutlineShaping.ancestors(data, taskId)
            val folds = folded.first()
            if (folds.any { it in ancestors }) container.folds.set(foldKey, folds - ancestors)
            _selectedId.value = taskId
            _scrollTo.value = taskId
        }
    }

    fun toggleFold(taskId: String) {
        container.scope.launch { container.folds.toggle(foldKey, taskId) }
    }

    fun foldAll() {
        val parents = outline.value.parentIds + board.value.columns.flatMap { c -> c.cards.filter { it.row.hasChildren }.map { it.id } }
        container.scope.launch { container.folds.set(foldKey, parents) }
    }

    fun unfoldAll() {
        container.scope.launch { container.folds.set(foldKey, emptySet()) }
    }

    fun setHideCompleted(hide: Boolean) {
        container.scope.launch { container.settings.putString(HIDE_COMPLETED, hide.toString()) }
    }

    fun setViewMode(mode: ListViewMode) {
        container.scope.launch { container.settings.putString(viewKey, mode.raw) }
    }

    // endregion

    // region Task commands

    /** Completes or reopens; with the Fold celebration a finished row then folds out of the outline. */
    fun toggleComplete(id: String) {
        val task = task(id) ?: return
        commands.toggleComplete(task)
        if (task.status == TaskStatus.OPEN) {
            if (celebration.value == CelebrationStyle.FOLD) {
                viewModelScope.launch {
                    delay(FOLD_DELAY_MILLIS)
                    foldedAway.value = foldedAway.value + id
                }
            }
        } else {
            foldedAway.value = foldedAway.value - id
        }
    }

    fun toggleInvalidate(id: String) {
        task(id)?.let { commands.toggleInvalidate(it) }
    }

    fun toggleList(id: String) {
        task(id)?.let { commands.toggleList(it) }
    }

    /**
     * Adds a task from the inline field: after [afterId] when given, else at
     * the end of the scope's top level (the Inbox's, in Everything). Returns
     * the new task's id so the next one goes after it.
     */
    suspend fun addTask(text: String, afterId: String?): String? {
        if (text.isBlank()) return null
        val session = container.awaitSession()
        val data = snapshot.value?.data
        val after = afterId?.let { task(it) }
        val targetList = after?.listId ?: listId ?: session.inboxId
        val parent = if (after != null) {
            after.parentTaskId
        } else {
            data?.let { d -> OutlineShaping.sections(d).firstOrNull { it.list.id == targetList }?.rootParentId }
        }
        var created: String? = null
        undo.performNow { repo ->
            created = repo.createTask(
                capturing = text.trim(), listId = targetList, parentTaskId = parent, adjacentTaskId = after?.id,
            ).id
        }
        return created
    }

    fun drop(rows: List<OutlineRow>, from: Int, to: Int) {
        val moved = rows.getOrNull(from) ?: return
        when (val drop = OutlineShaping.planDrop(rows, from, to)) {
            is OutlineDrop.Before -> undo.perform { it.moveTaskBefore(moved.id, drop.targetId) }
            OutlineDrop.ToEnd -> undo.perform { it.moveTaskWithinSiblings(moved.id, Int.MAX_VALUE / 2) }
            null -> if (from != to) undo.say("Drag among its siblings; indent or outdent to change its parent")
        }
    }

    // endregion

    // region Board and matrix

    fun moveCard(cardId: String, columnId: String) {
        if (board.value.columnOf(cardId)?.id == columnId) return
        undo.perform { it.setKanbanColumn(columnId, cardId) }
    }

    fun moveCardBy(cardId: String, offset: Int) {
        val columns = board.value.columns
        val index = columns.indexOfFirst { c -> c.cards.any { it.id == cardId } }
        if (index < 0) return
        val destination = (index + offset).coerceIn(0, columns.size - 1)
        if (destination != index) moveCard(cardId, columns[destination].id)
    }

    fun addColumn(title: String) {
        val name = title.trim()
        if (name.isEmpty()) return
        val columns = board.value.columnDefinitions
        val updated = columns + WorkspaceKanbanColumn(BoardShaping.uniqueColumnId(name, columns), name)
        undo.perform { it.setKanbanBoardColumns(updated, boardKey, label = "Add Board Column") }
    }

    /** Removes a column, moving its cards into the first remaining column in the same undo step. */
    fun removeColumn(columnId: String) {
        val shape = board.value
        if (shape.columns.size <= 1) return
        val remaining = shape.columnDefinitions.filter { it.id != columnId }
        val fallback = remaining.first()
        val moving = shape.columns.firstOrNull { it.id == columnId }?.cards?.map { it.id }.orEmpty()
        undo.perform {
            it.setKanbanBoardColumns(remaining, boardKey, movingTaskIds = moving, toColumn = fallback.id, label = "Remove Board Column")
        }
    }

    fun place(cardId: String, cell: MatrixCell?) {
        val position = cell?.position ?: TaskMatrixPosition(null, null)
        undo.perform { it.setMatrixPosition(position, cardId) }
    }

    // endregion

    // region The list itself

    fun renameList(name: String) {
        val id = listId ?: return
        undo.perform { it.renameList(id, name) }
    }

    fun setArchived(archived: Boolean) {
        val id = listId ?: return
        undo.perform { it.setListArchived(archived, id) }
    }

    fun toggleCompleted() {
        val list = list.value ?: return
        undo.perform { it.setListCompleted(list.completedAt == null, list.id) }
    }

    fun deleteList() {
        val id = listId ?: return
        undo.perform { it.deleteList(id) }
    }

    // endregion

    companion object {
        const val HIDE_COMPLETED = "outlineHidesCompleted"
        private const val FOLD_DELAY_MILLIS = 450L
    }
}
