package uk.co.maybeitsadam.takt.ui.search

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import uk.co.maybeitsadam.takt.core.TaskStatus
import uk.co.maybeitsadam.takt.data.workspace.TaskSearchResult
import uk.co.maybeitsadam.takt.ui.components.EmptyState
import uk.co.maybeitsadam.takt.ui.components.Format
import uk.co.maybeitsadam.takt.ui.components.Hairline
import uk.co.maybeitsadam.takt.ui.components.IconAction
import uk.co.maybeitsadam.takt.ui.components.TaktTopBar
import uk.co.maybeitsadam.takt.ui.components.SectionHeader
import uk.co.maybeitsadam.takt.ui.components.SettingsAction
import uk.co.maybeitsadam.takt.ui.components.Tag
import uk.co.maybeitsadam.takt.ui.components.TaskCheck
import uk.co.maybeitsadam.takt.ui.navigation.LocalShell
import uk.co.maybeitsadam.takt.ui.theme.TaktTheme
import uk.co.maybeitsadam.takt.ui.theme.Metrics
import uk.co.maybeitsadam.takt.ui.theme.PIcons
import uk.co.maybeitsadam.takt.ui.theme.parseHexColor

/**
 * Search: titles and notes across every list. Tap a result to open its list
 * with the task selected; long-press for its details; ↑/↓ and Enter from the
 * field do the same without leaving the keyboard.
 */
@Composable
fun SearchScreen() {
    val shell = LocalShell.current
    val model = viewModel { SearchViewModel(shell.container) }
    val query by model.query.collectAsStateWithLifecycle()
    val includeCompleted by model.includeCompleted.collectAsStateWithLifecycle()
    val state by model.state.collectAsStateWithLifecycle()
    val focus = remember { FocusRequester() }
    val focusManager = LocalFocusManager.current
    var selected by rememberSaveable(state.query) { mutableStateOf<Int?>(null) }
    val listState = rememberLazyListState()
    val results = state.results

    fun reveal(result: TaskSearchResult) {
        focusManager.clearFocus()
        shell.navigator.openList(result.list.id, revealTaskId = result.task.id)
    }

    LaunchedEffect(Unit) { focus.requestFocus() }
    LaunchedEffect(selected) { selected?.let { listState.animateScrollToItem(it + 1) } }

    Column(Modifier.fillMaxSize().background(TaktTheme.colors.paper).imePadding()) {
        TaktTopBar("Search", actions = { SettingsAction() })
        Column(Modifier.padding(horizontal = Metrics.lg, vertical = Metrics.sm), verticalArrangement = Arrangement.spacedBy(Metrics.sm)) {
            SearchField(
                value = query,
                onValueChange = model::setQuery,
                modifier = Modifier
                    .focusRequester(focus)
                    .onPreviewKeyEvent { event ->
                        if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                        when (event.key) {
                            Key.DirectionDown -> { selected = SearchMatching.move(selected, 1, results.size); true }
                            Key.DirectionUp -> { selected = SearchMatching.move(selected, -1, results.size); true }
                            Key.Enter, Key.NumPadEnter -> {
                                val index = selected ?: if (results.isNotEmpty()) 0 else null
                                index?.let { results.getOrNull(it) }?.let(::reveal)
                                index != null
                            }
                            else -> false
                        }
                    },
                onSubmit = { results.getOrNull(selected ?: 0)?.let(::reveal) },
            )
            Tag(
                "Include completed",
                selected = includeCompleted,
                color = if (includeCompleted) TaktTheme.colors.primary else TaktTheme.colors.mutedText,
                leading = if (includeCompleted) Icons.Filled.Check else null,
                modifier = Modifier
                    .testTag("search_include_completed")
                    .semantics { contentDescription = if (includeCompleted) "Include completed, on" else "Include completed, off" },
                onClick = { model.setIncludeCompleted(!includeCompleted) },
            )
        }
        Hairline()
        val trimmed = query.trim()
        when {
            trimmed.isEmpty() -> EmptyState("Search every task", detail = "Titles and notes, across all your lists.")
            results.isEmpty() && state.query == trimmed -> EmptyState(
                "No matches",
                detail = if (includeCompleted) null else "Completed tasks are hidden.",
            )
            else -> LazyColumn(Modifier.fillMaxSize().testTag("search_results"), state = listState) {
                item(key = "header", contentType = "header") {
                    SectionHeader(if (results.size == 1) "1 task" else "${results.size} tasks")
                }
                itemsIndexed(results, key = { _, r -> r.task.id }, contentType = { _, _ -> "result" }) { index, result ->
                    ResultRow(
                        result = result,
                        query = state.query.orEmpty(),
                        isSelected = index == selected,
                        onOpen = { reveal(result) },
                        onInspect = { model.inspect(result.task.id) },
                        onToggle = { model.toggle(result) },
                    )
                }
            }
        }
    }
}

@Composable
private fun SearchField(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    onSubmit: () -> Unit,
) {
    val colors = TaktTheme.colors
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        singleLine = true,
        textStyle = TaktTheme.type.field.copy(color = colors.ink),
        cursorBrush = SolidColor(colors.primary),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Text, imeAction = ImeAction.Search),
        keyboardActions = KeyboardActions(onSearch = { onSubmit() }),
        modifier = modifier
            .fillMaxWidth()
            .testTag("search_field")
            .semantics { contentDescription = "Search tasks" },
        decorationBox = { inner ->
            Row(
                Modifier
                    .fillMaxWidth()
                    .heightIn(min = Metrics.touchTarget)
                    .background(colors.raised, Metrics.control)
                    .border(BorderStroke(Metrics.hairline, colors.inputBorder), Metrics.control)
                    .padding(start = Metrics.md),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Filled.Search, null, tint = colors.mutedText, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(Metrics.sm))
                Box(Modifier.weight(1f)) {
                    if (value.isEmpty()) Text("Search tasks", style = TaktTheme.type.field, color = colors.dimText)
                    inner()
                }
                if (value.isNotEmpty()) IconAction(Icons.Filled.Clear, "Clear search") { onValueChange("") }
            }
        },
    )
}

@Composable
private fun ResultRow(
    result: TaskSearchResult,
    query: String,
    isSelected: Boolean,
    onOpen: () -> Unit,
    onInspect: () -> Unit,
    onToggle: () -> Unit,
) {
    val colors = TaktTheme.colors
    val task = result.task
    val open = task.status == TaskStatus.OPEN
    val highlight = SpanStyle(color = colors.ink, fontWeight = FontWeight.SemiBold, background = colors.warning.copy(alpha = 0.22f))
    val title = remember(task.title, query, highlight) { highlighted(task.title, query, highlight) }
    val snippet = result.notesSnippet?.takeIf { it.isNotBlank() }
    val listColor = parseHexColor(result.list.colorHex) ?: colors.mutedText
    Column(
        Modifier
            .fillMaxWidth()
            .background(if (isSelected) colors.hover else colors.paper)
            .combinedClickable(onClickLabel = "Reveal in list", onLongClickLabel = "Open details", onLongClick = onInspect, onClick = onOpen)
            .semantics { contentDescription = "Search result ${task.title}" }
            .testTag("search_result"),
    ) {
        Row(Modifier.fillMaxWidth().padding(end = Metrics.lg, top = Metrics.xs, bottom = Metrics.xs), verticalAlignment = Alignment.Top) {
            TaskCheck(task.status, isList = task.isList, label = task.title, onToggle = onToggle)
            Column(Modifier.weight(1f).padding(top = Metrics.md), verticalArrangement = Arrangement.spacedBy(Metrics.xxs)) {
                Text(
                    title,
                    style = TaktTheme.type.body,
                    color = if (open) colors.ink else colors.mutedText,
                    textDecoration = if (open) null else TextDecoration.LineThrough,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                if (snippet != null) {
                    Text(
                        remember(snippet, query, highlight) { highlighted(snippet, query, highlight) },
                        style = TaktTheme.type.small,
                        color = colors.mutedText,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Metrics.xs)) {
                    Icon(PIcons.ListIcon, null, tint = listColor, modifier = Modifier.size(12.dp))
                    Text(result.list.name, style = TaktTheme.type.small, color = listColor, maxLines = 1)
                    statusLabel(task.status)?.let { label ->
                        Spacer(Modifier.width(Metrics.xs))
                        Text(label, style = TaktTheme.type.small, color = colors.dimText)
                    }
                }
            }
            task.dueAt?.let { due ->
                val overdue = open && due.isBefore(java.time.Instant.now())
                Tag(
                    Format.due(due),
                    color = if (overdue) colors.danger else colors.mutedText,
                    mono = true,
                    modifier = Modifier.padding(top = Metrics.md, start = Metrics.sm),
                )
            }
        }
        Hairline(Modifier.padding(start = Metrics.touchTarget), color = colors.borderMuted)
    }
}

private fun statusLabel(status: TaskStatus): String? = when (status) {
    TaskStatus.OPEN -> null
    TaskStatus.COMPLETED -> "Done"
    TaskStatus.CANCELLED -> "Cancelled"
}

private fun highlighted(text: String, query: String, style: SpanStyle): AnnotatedString = buildAnnotatedString {
    append(text)
    for (range in SearchMatching.ranges(text, query)) addStyle(style, range.first, range.last + 1)
}
