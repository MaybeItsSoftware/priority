package uk.co.maybeitsadam.priority.ui.lists

import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.PageSize
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.launch
import uk.co.maybeitsadam.priority.app.CelebrationStyle
import uk.co.maybeitsadam.priority.ui.commands.Chord
import uk.co.maybeitsadam.priority.ui.components.Card
import uk.co.maybeitsadam.priority.ui.components.EmptyState
import uk.co.maybeitsadam.priority.ui.components.Hairline
import uk.co.maybeitsadam.priority.ui.components.IconAction
import uk.co.maybeitsadam.priority.ui.components.MonoText
import uk.co.maybeitsadam.priority.ui.components.Tag
import uk.co.maybeitsadam.priority.ui.navigation.LocalShell
import uk.co.maybeitsadam.priority.ui.theme.PriorityTheme
import uk.co.maybeitsadam.priority.ui.theme.Metrics

/** How many subtask rows a card draws before "+N more", as on the Mac. */
private const val VISIBLE_SUBTASK_ROWS = 12

/**
 * The board: a pager of kanban columns (several abreast on a wide window),
 * column tabs above, cards with their subtasks folded as the outline folds
 * them, and moving cards between columns from a menu or Alt+Shift+←/→.
 */
@Composable
internal fun BoardPane(vm: ListViewModel, actions: TaskActions, show: (ListDialog) -> Unit, modifier: Modifier = Modifier) {
    val shape by vm.board.collectAsStateWithLifecycle()
    val selected by vm.selectedId.collectAsStateWithLifecycle()
    val celebration by vm.celebration.collectAsStateWithLifecycle()
    val wide = LocalShell.current.layout.isWide
    val columns = shape.columns
    val pager = rememberPagerState { columns.size }
    val scope = rememberCoroutineScope()
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }

    // Follow the selected card when it moves column.
    LaunchedEffect(selected, shape) {
        val index = columns.indexOfFirst { c -> c.cards.any { it.id == selected } }
        if (index >= 0 && index != pager.currentPage && !wide) pager.animateScrollToPage(index)
    }

    Column(
        modifier
            .fillMaxSize()
            .focusRequester(focus)
            .focusable()
            .onKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown) return@onKeyEvent false
                val current = columns.getOrNull(pager.currentPage)
                val cards = (columns.firstOrNull { c -> c.cards.any { it.id == selected } } ?: current)?.cards.orEmpty()
                val card = cards.firstOrNull { it.id == selected }
                when {
                    Chord(Key.DirectionLeft, shift = true, alt = true).matches(event) -> card?.let { vm.moveCardBy(it.id, -1) }
                    Chord(Key.DirectionRight, shift = true, alt = true).matches(event) -> card?.let { vm.moveCardBy(it.id, 1) }
                    Chord(Key.C, ctrl = true, shift = true).matches(event) -> show(ListDialog.AddColumn)
                    Chord(Key.J).matches(event) || Chord(Key.DirectionDown).matches(event) -> vm.selectAdjacent(cards.map { it.row }, 1)
                    Chord(Key.K).matches(event) || Chord(Key.DirectionUp).matches(event) -> vm.selectAdjacent(cards.map { it.row }, -1)
                    Chord(Key.DirectionLeft).matches(event) -> scope.launch { pager.animateScrollToPage((pager.currentPage - 1).coerceAtLeast(0)) }
                    Chord(Key.DirectionRight).matches(event) -> scope.launch { pager.animateScrollToPage((pager.currentPage + 1).coerceAtMost(columns.size - 1)) }
                    Chord(Key.DirectionLeft, ctrl = true).matches(event) -> vm.foldAll()
                    Chord(Key.DirectionRight, ctrl = true).matches(event) -> vm.unfoldAll()
                    else -> return@onKeyEvent actions.handleKey(event, card?.row)
                }
                true
            },
    ) {
        // Column tabs: the page indicator, and a way to jump.
        Row(Modifier.fillMaxWidth().padding(start = Metrics.sm), verticalAlignment = Alignment.CenterVertically) {
            LazyRow(
                Modifier.weight(1f).testTag("board_tabs"),
                horizontalArrangement = Arrangement.spacedBy(Metrics.xs),
                contentPadding = PaddingValues(vertical = Metrics.xxs),
            ) {
                itemsIndexed(columns, key = { _, c -> c.id }, contentType = { _, _ -> "tab" }) { index, column ->
                    Tag(
                        "${column.title} ${column.cards.size}",
                        selected = index == pager.currentPage,
                        color = if (index == pager.currentPage) PriorityTheme.colors.primary else PriorityTheme.colors.mutedText,
                        onClick = { scope.launch { pager.animateScrollToPage(index) } },
                    )
                }
            }
            IconAction(Icons.Filled.Add, "Add a board column", onClick = { show(ListDialog.AddColumn) })
            ColumnMenu(
                enabled = columns.size > 1,
                onRemove = { columns.getOrNull(pager.currentPage)?.let { show(ListDialog.RemoveColumn(it.id, it.title)) } },
            )
        }
        Hairline()
        if (shape.isLoaded && columns.isEmpty()) {
            EmptyState("No columns")
            return@Column
        }
        HorizontalPager(
            state = pager,
            modifier = Modifier.fillMaxSize().testTag("board_pager"),
            pageSize = if (wide) PageSize.Fixed(320.dp) else PageSize.Fill,
            beyondViewportPageCount = 1,
            key = { columns.getOrNull(it)?.id ?: it },
        ) { page ->
            val column = columns.getOrNull(page) ?: return@HorizontalPager
            BoardColumnView(column, selected, celebration, actions, vm)
        }
    }
}

@Composable
private fun ColumnMenu(enabled: Boolean, onRemove: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconAction(Icons.Filled.MoreVert, "Column actions", onClick = { open = true })
        PMenu(open, { open = false }) {
            PMenuItem("Remove this column", Icons.Filled.Delete, destructive = true, enabled = enabled, onClick = {
                open = false
                onRemove()
            })
        }
    }
}

@Composable
private fun BoardColumnView(
    column: BoardColumnModel,
    selected: String?,
    celebration: CelebrationStyle,
    actions: TaskActions,
    vm: ListViewModel,
) {
    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 36.dp).padding(horizontal = Metrics.lg),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(column.title, style = PriorityTheme.type.label, color = PriorityTheme.colors.mutedText, modifier = Modifier.weight(1f))
            MonoText(column.cards.size.toString(), style = PriorityTheme.type.monoSmall, color = PriorityTheme.colors.dimText)
        }
        LazyColumn(
            Modifier.fillMaxSize().testTag("board_column_${column.id}"),
            contentPadding = PaddingValues(start = Metrics.md, end = Metrics.md, bottom = Metrics.xl),
            verticalArrangement = Arrangement.spacedBy(Metrics.sm),
        ) {
            if (column.cards.isEmpty()) {
                item(key = "empty", contentType = "empty") {
                    Text("No cards", style = PriorityTheme.type.small, color = PriorityTheme.colors.dimText, modifier = Modifier.padding(Metrics.sm))
                }
            }
            items(column.cards, key = { it.id }, contentType = { "card" }) { card ->
                BoardCardView(card, card.id == selected, celebration, actions, vm, Modifier.animateItem())
            }
        }
    }
}

@Composable
private fun BoardCardView(
    card: BoardCard,
    isSelected: Boolean,
    celebration: CelebrationStyle,
    actions: TaskActions,
    vm: ListViewModel,
    modifier: Modifier = Modifier,
) {
    var menu by remember { mutableStateOf(false) }
    val row = card.row
    Box(modifier) {
        Card(Modifier.fillMaxWidth(), selected = isSelected) {
            Column(
                Modifier
                    .fillMaxWidth()
                    .combinedClickable(onClick = { actions.tap(row.id) }, onLongClick = { menu = true }, onLongClickLabel = "Card actions")
                    .padding(end = Metrics.sm, bottom = Metrics.xs),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CelebratedCheck(row.status, row.isList, row.title, celebration) { actions.toggleComplete(row.id) }
                    TaskTitle(row.title, row.status, celebration, Modifier.weight(1f).padding(vertical = Metrics.sm), maxLines = 3)
                    if (row.hasChildren) FoldChevron(row.title, row.isFolded, onToggle = { actions.toggleFold(row.id) })
                }
                val detail = card.parentTitle?.let { "Under $it" } ?: card.listName
                if (detail != null) {
                    Text(detail, style = PriorityTheme.type.small, color = PriorityTheme.colors.mutedText, maxLines = 1, modifier = Modifier.padding(start = Metrics.touchTarget))
                }
                Box(Modifier.padding(start = Metrics.touchTarget).heightIn(max = 24.dp)) { RowMarkers(row) }
                for (sub in card.subtasks.take(VISIBLE_SUBTASK_ROWS)) {
                    SubtaskRow(sub, celebration, actions)
                }
                if (card.subtasks.size > VISIBLE_SUBTASK_ROWS) {
                    Text(
                        "+${card.subtasks.size - VISIBLE_SUBTASK_ROWS} more", style = PriorityTheme.type.small, color = PriorityTheme.colors.dimText,
                        modifier = Modifier.padding(start = Metrics.touchTarget, top = Metrics.xxs),
                    )
                } else if (row.isFolded && card.subtaskCount > 0) {
                    Text(
                        "${card.subtaskCount} folded", style = PriorityTheme.type.small, color = PriorityTheme.colors.dimText,
                        modifier = Modifier.padding(start = Metrics.touchTarget, top = Metrics.xxs),
                    )
                }
            }
        }
        PMenu(menu, { menu = false }) {
            PMenuItem("Move to column…", uk.co.maybeitsadam.priority.ui.theme.PIcons.Board, trailing = "Alt+Shift+←/→", onClick = {
                menu = false
                actions.askMoveCard(row)
            })
            PMenuItem("Column to the left", onClick = {
                menu = false
                vm.moveCardBy(row.id, -1)
            })
            PMenuItem("Column to the right", onClick = {
                menu = false
                vm.moveCardBy(row.id, 1)
            })
            PMenuDivider()
            TaskMenuItems(row, actions, close = { menu = false }, structure = card.parentTitle == null)
        }
    }
}

@Composable
private fun SubtaskRow(row: OutlineRow, celebration: CelebrationStyle, actions: TaskActions) {
    Row(
        Modifier.fillMaxWidth().padding(start = Metrics.lg + Metrics.indent * row.depth),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CelebratedCheck(row.status, row.isList, row.title, celebration) { actions.toggleComplete(row.id) }
        TaskTitle(row.title, row.status, celebration, Modifier.weight(1f), style = PriorityTheme.type.small, maxLines = 2)
        if (row.hasChildren) {
            FoldChevron(row.title, row.isFolded, onToggle = { actions.toggleFold(row.id) })
        } else {
            Spacer(Modifier.width(Metrics.xs))
        }
    }
}
