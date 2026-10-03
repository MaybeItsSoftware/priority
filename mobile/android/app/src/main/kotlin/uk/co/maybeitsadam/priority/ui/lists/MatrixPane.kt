package uk.co.maybeitsadam.priority.ui.lists

import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import uk.co.maybeitsadam.priority.app.CelebrationStyle
import uk.co.maybeitsadam.priority.ui.commands.Chord
import uk.co.maybeitsadam.priority.ui.components.Hairline
import uk.co.maybeitsadam.priority.ui.components.MonoText
import uk.co.maybeitsadam.priority.ui.components.VerticalHairline
import uk.co.maybeitsadam.priority.ui.theme.PriorityTheme
import uk.co.maybeitsadam.priority.ui.theme.Metrics
import uk.co.maybeitsadam.priority.ui.theme.PIcons

/** A quadrant's hue, as the Mac picks it: danger, primary, warning, dim. */
@Composable
internal fun MatrixCell.tint(): Color = when (this) {
    MatrixCell.DO_NOW -> PriorityTheme.colors.danger
    MatrixCell.SCHEDULE -> PriorityTheme.colors.primary
    MatrixCell.DELEGATE -> PriorityTheme.colors.warning
    MatrixCell.ELIMINATE -> PriorityTheme.colors.dimText
}

/**
 * The Eisenhower matrix over the scope's cards: unplaced tasks first, then
 * the four quadrants in a 2x2 grid, each its own scrolling list. Alt+1…4
 * files the selected task.
 */
@Composable
internal fun MatrixPane(vm: ListViewModel, actions: TaskActions, modifier: Modifier = Modifier) {
    val shape by vm.matrix.collectAsStateWithLifecycle()
    val selected by vm.selectedId.collectAsStateWithLifecycle()
    val celebration by vm.celebration.collectAsStateWithLifecycle()
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
    val ordered = remember(shape) { (shape.unplaced + shape.quadrants.flatMap { it.cards }).map { it.row } }

    Column(
        modifier
            .fillMaxSize()
            .focusRequester(focus)
            .focusable()
            .onKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown) return@onKeyEvent false
                val row = ordered.firstOrNull { it.id == selected }
                val placement = listOf(Key.One, Key.Two, Key.Three, Key.Four).indexOfFirst { Chord(it, alt = true).matches(event) }
                when {
                    placement >= 0 -> row?.let { vm.place(it.id, MatrixCell.entries[placement]) }
                    Chord(Key.J).matches(event) || Chord(Key.DirectionDown).matches(event) -> vm.selectAdjacent(ordered, 1)
                    Chord(Key.K).matches(event) || Chord(Key.DirectionUp).matches(event) -> vm.selectAdjacent(ordered, -1)
                    else -> return@onKeyEvent actions.handleKey(event, row)
                }
                true
            },
    ) {
        if (shape.unplaced.isNotEmpty()) {
            Row(Modifier.fillMaxWidth().heightIn(min = 36.dp).padding(horizontal = Metrics.lg), verticalAlignment = Alignment.CenterVertically) {
                Text("Unplaced", style = PriorityTheme.type.label, color = PriorityTheme.colors.mutedText, modifier = Modifier.weight(1f))
                MonoText(shape.unplaced.size.toString(), style = PriorityTheme.type.monoSmall, color = PriorityTheme.colors.dimText)
            }
            LazyColumn(Modifier.fillMaxWidth().heightIn(max = 168.dp).testTag("matrix_unplaced")) {
                items(shape.unplaced, key = { it.id }, contentType = { "matrix_row" }) { card ->
                    MatrixRow(card, card.id == selected, null, celebration, actions, vm)
                }
            }
            Hairline()
        }
        val cells = shape.quadrants
        Column(Modifier.fillMaxSize().testTag("matrix_grid")) {
            for (pair in cells.chunked(2)) {
                Row(Modifier.fillMaxWidth().weight(1f)) {
                    pair.forEachIndexed { index, quadrant ->
                        if (index > 0) VerticalHairline()
                        QuadrantView(quadrant, selected, celebration, actions, vm, Modifier.weight(1f).fillMaxHeight())
                    }
                }
                Hairline()
            }
        }
    }
}

@Composable
private fun QuadrantView(
    quadrant: MatrixQuadrantModel,
    selected: String?,
    celebration: CelebrationStyle,
    actions: TaskActions,
    vm: ListViewModel,
    modifier: Modifier,
) {
    val tint = quadrant.cell.tint()
    Column(modifier.testTag("matrix_${quadrant.cell.name.lowercase()}")) {
        Row(Modifier.fillMaxWidth().heightIn(min = 36.dp).padding(horizontal = Metrics.md), verticalAlignment = Alignment.CenterVertically) {
            Text(quadrant.cell.title, style = PriorityTheme.type.label, color = tint, modifier = Modifier.weight(1f), maxLines = 1)
            MonoText(quadrant.cards.size.toString(), style = PriorityTheme.type.monoSmall, color = PriorityTheme.colors.dimText)
        }
        if (quadrant.cards.isEmpty()) {
            Text(quadrant.cell.detail, style = PriorityTheme.type.small, color = PriorityTheme.colors.dimText, modifier = Modifier.padding(horizontal = Metrics.md))
        }
        LazyColumn(Modifier.fillMaxSize()) {
            items(quadrant.cards, key = { it.id }, contentType = { "matrix_row" }) { card ->
                MatrixRow(card, card.id == selected, quadrant.cell, celebration, actions, vm)
            }
        }
    }
}

@Composable
private fun MatrixRow(
    card: BoardCard,
    isSelected: Boolean,
    cell: MatrixCell?,
    celebration: CelebrationStyle,
    actions: TaskActions,
    vm: ListViewModel,
) {
    var menu by remember { mutableStateOf(false) }
    val row = card.row
    Box {
        Row(
            Modifier
                .fillMaxWidth()
                .background(if (isSelected) PriorityTheme.colors.primary.copy(alpha = 0.10f) else Color.Transparent)
                .heightIn(min = Metrics.touchTarget)
                .combinedClickable(onClick = { actions.tap(row.id) }, onLongClick = { menu = true }, onLongClickLabel = "Task actions")
                .padding(end = Metrics.sm),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CelebratedCheck(row.status, row.isList, row.title, celebration) { actions.toggleComplete(row.id) }
            Column(Modifier.weight(1f)) {
                TaskTitle(row.title, row.status, celebration, style = PriorityTheme.type.small, maxLines = 2)
                card.listName?.let { Text(it, style = PriorityTheme.type.small, color = PriorityTheme.colors.mutedText, maxLines = 1, overflow = TextOverflow.Ellipsis) }
            }
        }
        PMenu(menu, { menu = false }) {
            MatrixCell.entries.forEachIndexed { index, target ->
                PMenuItem(
                    target.title, PIcons.Grid, trailing = "Alt+${index + 1}", enabled = target != cell,
                    onClick = {
                        menu = false
                        vm.place(row.id, target)
                    },
                )
            }
            if (cell != null) {
                PMenuItem("Take off the matrix", Icons.Filled.Clear, onClick = {
                    menu = false
                    vm.place(row.id, null)
                })
            }
            PMenuDivider()
            TaskMenuItems(row, actions, close = { menu = false }, structure = false)
        }
    }
}
