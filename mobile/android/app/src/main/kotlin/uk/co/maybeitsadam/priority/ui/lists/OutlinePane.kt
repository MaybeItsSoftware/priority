package uk.co.maybeitsadam.priority.ui.lists

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Icon
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableFloatState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.launch
import uk.co.maybeitsadam.priority.app.CelebrationStyle
import uk.co.maybeitsadam.priority.ui.commands.Chord
import uk.co.maybeitsadam.priority.ui.components.EmptyState
import uk.co.maybeitsadam.priority.ui.components.Hairline
import uk.co.maybeitsadam.priority.ui.components.MonoText
import uk.co.maybeitsadam.priority.ui.navigation.LocalShell
import uk.co.maybeitsadam.priority.ui.theme.PriorityTheme
import uk.co.maybeitsadam.priority.ui.theme.Metrics
import uk.co.maybeitsadam.priority.ui.theme.PIcons

/** The outline's drag in progress: which row, and how far it has moved. */
private class OutlineDrag {
    var id by mutableStateOf<String?>(null)
    val offset: MutableFloatState = mutableFloatStateOf(0f)
}

/**
 * The Checkvist-style outline: folding in place, swipes to complete and
 * cancel, a long-press menu with every task command, drag to reorder among
 * siblings, an inline add field, and the hardware keyboard.
 */
@Composable
internal fun OutlinePane(vm: ListViewModel, actions: TaskActions, modifier: Modifier = Modifier) {
    val shape by vm.outline.collectAsStateWithLifecycle()
    val selected by vm.selectedId.collectAsStateWithLifecycle()
    val celebration by vm.celebration.collectAsStateWithLifecycle()
    val scrollTo by vm.scrollTo.collectAsStateWithLifecycle()
    val listState = rememberLazyListState()
    val focus = remember { FocusRequester() }
    val drag = remember { OutlineDrag() }
    val navigator = LocalShell.current.navigator

    LaunchedEffect(scrollTo, shape) {
        val id = scrollTo ?: return@LaunchedEffect
        val index = shape.entries.indexOfFirst { it.key == id }
        if (index >= 0) {
            val visible = listState.layoutInfo.visibleItemsInfo
            val shown = visible.any { it.index == index && it.offset >= 0 && it.offset + it.size <= listState.layoutInfo.viewportEndOffset }
            if (!shown) listState.animateScrollToItem(index, scrollOffset = -listState.layoutInfo.viewportSize.height / 3)
            vm.consumeScroll()
        }
    }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }

    Box(
        modifier
            .fillMaxSize()
            .focusRequester(focus)
            .focusable()
            .onKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown) return@onKeyEvent false
                val rows = shape.rows
                val row = rows.firstOrNull { it.id == selected }
                when {
                    Chord(Key.J).matches(event) || Chord(Key.DirectionDown).matches(event) -> vm.selectAdjacent(rows, 1)
                    Chord(Key.K).matches(event) || Chord(Key.DirectionUp).matches(event) -> vm.selectAdjacent(rows, -1)
                    Chord(Key.DirectionLeft, ctrl = true).matches(event) -> vm.foldAll()
                    Chord(Key.DirectionRight, ctrl = true).matches(event) -> vm.unfoldAll()
                    else -> return@onKeyEvent actions.handleKey(event, row)
                }
                true
            },
    ) {
        if (shape.isLoaded && shape.entries.isEmpty()) {
            Box(Modifier.fillMaxSize()) {
                LazyColumn(Modifier.fillMaxSize().testTag("outline_list").imePadding(), state = listState) {
                    item(key = "empty", contentType = "empty") {
                        EmptyState(if (vm.isEverything) "Nothing open anywhere" else "No tasks yet", detail = "Add one below, or with the field above.")
                    }
                    item(key = "add", contentType = "add") { AddField(vm, focusAfter = focus) }
                }
            }
            return@Box
        }
        LazyColumn(Modifier.fillMaxSize().testTag("outline_list").imePadding(), state = listState) {
            items(shape.entries, key = { it.key }, contentType = { it.contentType }) { entry ->
                when (entry) {
                    is OutlineEntry.Header -> ListHeaderRow(entry) { navigator.openList(entry.listId) }
                    is OutlineEntry.Task -> {
                        val row = entry.row
                        val isDragging = drag.id == row.id
                        OutlineRowView(
                            row = row,
                            isSelected = row.id == selected,
                            celebration = celebration,
                            actions = actions,
                            onTap = {
                                actions.tap(row.id)
                                runCatching { focus.requestFocus() }
                            },
                            dragHandle = Modifier.pointerInput(row.id) {
                                detectDragGestures(
                                    onDragStart = {
                                        drag.id = row.id
                                        drag.offset.floatValue = 0f
                                    },
                                    onDragEnd = {
                                        finishDrag(vm, shape.rows, row.id, drag, listState)
                                    },
                                    onDragCancel = {
                                        drag.id = null
                                        drag.offset.floatValue = 0f
                                    },
                                    onDrag = { change, amount ->
                                        change.consume()
                                        drag.offset.floatValue += amount.y
                                    },
                                )
                            },
                            modifier = Modifier
                                .then(if (isDragging) Modifier.zIndex(1f).graphicsLayer { translationY = drag.offset.floatValue } else Modifier.animateItem()),
                        )
                    }
                }
            }
            item(key = "add", contentType = "add") { AddField(vm, focusAfter = focus) }
        }
    }
}

/** Where the dragged row's centre now sits among the drawn rows, and the move that makes. */
private fun finishDrag(vm: ListViewModel, rows: List<OutlineRow>, id: String, drag: OutlineDrag, state: LazyListState) {
    val visible = state.layoutInfo.visibleItemsInfo
    val dragged = visible.firstOrNull { it.key == id }
    val from = rows.indexOfFirst { it.id == id }
    if (dragged != null && from >= 0) {
        val centre = dragged.offset + drag.offset.floatValue + dragged.size / 2f
        val rowIds = rows.withIndex().associate { it.value.id to it.index }
        val candidates = visible.filter { it.key != id && it.key in rowIds }
        val below = candidates.firstOrNull { it.offset + it.size / 2f > centre }
        val to = when {
            below != null -> rowIds.getValue(below.key as String)
            candidates.isNotEmpty() -> rowIds.getValue(candidates.last().key as String) + 1
            else -> from
        }
        vm.drop(rows, from, to)
    }
    drag.id = null
    drag.offset.floatValue = 0f
}

@Composable
private fun ListHeaderRow(header: OutlineEntry.Header, onOpen: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .background(PriorityTheme.colors.paper)
            .heightIn(min = 40.dp)
            .clickable(onClick = onOpen)
            .padding(horizontal = Metrics.lg)
            .semantics { contentDescription = "Open ${header.name}" },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(header.name, style = PriorityTheme.type.label, color = PriorityTheme.colors.mutedText, modifier = Modifier.weight(1f))
        MonoText(header.count.toString(), style = PriorityTheme.type.monoSmall, color = PriorityTheme.colors.dimText)
    }
    Hairline(color = PriorityTheme.colors.borderMuted)
}

@Composable
private fun OutlineRowView(
    row: OutlineRow,
    isSelected: Boolean,
    celebration: CelebrationStyle,
    actions: TaskActions,
    onTap: () -> Unit,
    dragHandle: Modifier,
    modifier: Modifier = Modifier,
) {
    var menu by remember { mutableStateOf(false) }
    val dismiss = rememberSwipeToDismissBoxState()
    val scope = rememberCoroutineScope()
    SwipeToDismissBox(
        state = dismiss,
        modifier = modifier,
        backgroundContent = { SwipeBackground(dismiss.dismissDirection, row) },
        onDismiss = { value ->
            when (value) {
                SwipeToDismissBoxValue.StartToEnd -> actions.toggleComplete(row.id)
                SwipeToDismissBoxValue.EndToStart -> actions.toggleInvalidate(row.id)
                SwipeToDismissBoxValue.Settled -> Unit
            }
            scope.launch { dismiss.reset() }
        },
    ) {
        val colors = PriorityTheme.colors
        Box {
            Row(
                Modifier
                    .fillMaxWidth()
                    .background(if (isSelected) colors.primary.copy(alpha = 0.10f) else colors.paper)
                    .heightIn(min = Metrics.rowHeight)
                    .combinedClickable(onClick = onTap, onLongClick = { menu = true }, onLongClickLabel = "Task actions")
                    .padding(start = Metrics.xs + Metrics.indent * row.depth, end = Metrics.xs),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (row.hasChildren) {
                    FoldChevron(row.title, row.isFolded, onToggle = { actions.toggleFold(row.id) })
                } else {
                    Spacer(Modifier.width(32.dp))
                }
                CelebratedCheck(row.status, row.isList, row.title, celebration) { actions.toggleComplete(row.id) }
                if (row.isList) {
                    Icon(ListIcons.Nested, "List", tint = colors.mutedText, modifier = Modifier.padding(end = Metrics.xs + Metrics.xxs).size(16.dp))
                }
                TaskTitle(
                    row.title, row.status, celebration,
                    style = if (row.isList) PriorityTheme.type.bodyStrong else PriorityTheme.type.body,
                    modifier = Modifier.weight(1f, fill = true).padding(vertical = Metrics.xs),
                )
                RowMarkers(row, Modifier.padding(start = Metrics.xs).heightIn(min = 24.dp))
                Box(
                    dragHandle
                        .width(36.dp)
                        .heightIn(min = Metrics.touchTarget)
                        .semantics { contentDescription = "Reorder ${row.title}" },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(PIcons.DragHandle, null, tint = colors.dimText, modifier = Modifier.size(18.dp))
                }
            }
            PMenu(expanded = menu, onDismiss = { menu = false }) {
                TaskMenuItems(row, actions, close = { menu = false })
            }
        }
    }
}

/** Emerald behind a swipe right (complete), raspberry behind a swipe left (cancel): tinted, not solid. */
@Composable
private fun SwipeBackground(direction: SwipeToDismissBoxValue, row: OutlineRow) {
    val colors = PriorityTheme.colors
    val (tint, icon, text, alignment) = when (direction) {
        SwipeToDismissBoxValue.StartToEnd -> Quad(colors.success, Icons.Filled.Check, if (row.status == uk.co.maybeitsadam.priority.core.TaskStatus.OPEN) "Complete" else "Reopen", Alignment.CenterStart)
        SwipeToDismissBoxValue.EndToStart -> Quad(colors.danger, Icons.Filled.Close, if (row.status == uk.co.maybeitsadam.priority.core.TaskStatus.CANCELLED) "Reinstate" else "Cancel", Alignment.CenterEnd)
        SwipeToDismissBoxValue.Settled -> Quad(colors.paper, null, "", Alignment.Center)
    }
    Box(
        Modifier.fillMaxSize().background(colors.paper).background(tint.copy(alpha = 0.14f)).padding(horizontal = Metrics.lg),
        contentAlignment = alignment,
    ) {
        if (icon != null) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Metrics.xs + Metrics.xxs)) {
                Icon(icon, null, tint = tint, modifier = Modifier.size(18.dp))
                Text(text, style = PriorityTheme.type.label, color = tint)
            }
        }
    }
}

private data class Quad(
    val tint: androidx.compose.ui.graphics.Color,
    val icon: androidx.compose.ui.graphics.vector.ImageVector?,
    val text: String,
    val alignment: Alignment,
)

/**
 * The inline add field at the foot of the outline. Enter files the task and
 * keeps the field, so the next one goes in after it, Checkvist-style.
 */
@Composable
private fun AddField(vm: ListViewModel, focusAfter: FocusRequester) {
    var text by remember { mutableStateOf("") }
    var lastAdded by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val submit = {
        val value = text
        if (value.isNotBlank()) {
            text = ""
            scope.launch { lastAdded = vm.addTask(value, lastAdded) ?: lastAdded }
        }
    }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = Metrics.md, vertical = Metrics.sm),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        PTextField(
            value = text,
            onValueChange = { text = it },
            placeholder = if (vm.isEverything) "Add a task to the Inbox" else "Add a task",
            modifier = Modifier
                .weight(1f)
                .testTag("outline_add_field")
                .onKeyEvent { event ->
                    // Escape leaves the field for the outline's own keys.
                    if (event.type == KeyEventType.KeyDown && event.key == Key.Escape) {
                        lastAdded = null
                        runCatching { focusAfter.requestFocus() }
                        true
                    } else {
                        false
                    }
                },
            imeAction = ImeAction.Done,
            onSubmit = submit,
        )
    }
}
