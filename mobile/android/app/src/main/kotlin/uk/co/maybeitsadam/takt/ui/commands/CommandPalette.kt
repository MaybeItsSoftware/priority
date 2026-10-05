package uk.co.maybeitsadam.takt.ui.commands

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
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
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import uk.co.maybeitsadam.takt.ui.components.Hairline
import uk.co.maybeitsadam.takt.ui.theme.TaktTheme
import uk.co.maybeitsadam.takt.ui.theme.Metrics

/**
 * Ctrl+K: a searchable list of every command the shell and the visible
 * screens offer, with their keys. Up/Down move, Enter runs, Escape closes.
 */
@Composable
fun CommandPalette(commands: List<PaletteCommand>, onDismiss: () -> Unit) {
    var query by remember { mutableStateOf("") }
    var selected by remember { mutableIntStateOf(0) }
    val focus = remember { FocusRequester() }
    val matches by remember(commands) {
        derivedStateOf {
            val words = query.trim().lowercase().split(" ").filter { it.isNotEmpty() }
            commands.distinctBy { it.id }.filter { command ->
                val haystack = "${command.title} ${command.group}".lowercase()
                words.all { it in haystack }
            }
        }
    }
    fun run(command: PaletteCommand) {
        onDismiss()
        command.run()
    }
    LaunchedEffect(Unit) { focus.requestFocus() }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(
            Modifier
                .padding(Metrics.lg)
                .widthIn(max = 560.dp)
                .fillMaxWidth()
                .background(TaktTheme.colors.raised, Metrics.card)
                .border(BorderStroke(Metrics.hairline, TaktTheme.colors.border), Metrics.card)
                .testTag("command_palette"),
        ) {
            BasicTextField(
                value = query,
                onValueChange = { query = it; selected = 0 },
                singleLine = true,
                textStyle = TaktTheme.type.body.copy(color = TaktTheme.colors.ink),
                cursorBrush = SolidColor(TaktTheme.colors.primary),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Go),
                keyboardActions = KeyboardActions(onGo = { matches.getOrNull(selected)?.let(::run) }),
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = Metrics.touchTarget)
                    .padding(horizontal = Metrics.lg, vertical = Metrics.md)
                    .focusRequester(focus)
                    .onPreviewKeyEvent { event ->
                        if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                        when (event.key) {
                            Key.DirectionDown -> { selected = (selected + 1).coerceAtMost(matches.size - 1); true }
                            Key.DirectionUp -> { selected = (selected - 1).coerceAtLeast(0); true }
                            Key.Enter, Key.NumPadEnter -> { matches.getOrNull(selected)?.let(::run); true }
                            Key.Escape -> { onDismiss(); true }
                            else -> false
                        }
                    },
                decorationBox = { inner ->
                    if (query.isEmpty()) Text("Run a command…", style = TaktTheme.type.body, color = TaktTheme.colors.dimText)
                    inner()
                },
            )
            Hairline()
            LazyColumn(Modifier.heightIn(max = 420.dp)) {
                items(matches.size, key = { matches[it].id }, contentType = { "command" }) { index ->
                    val command = matches[index]
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .heightIn(min = Metrics.touchTarget)
                            .background(if (index == selected) TaktTheme.colors.hover else TaktTheme.colors.raised)
                            .clickable { run(command) }
                            .padding(horizontal = Metrics.lg),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text(command.title, style = TaktTheme.type.body, color = TaktTheme.colors.ink)
                            Text(command.group, style = TaktTheme.type.small, color = TaktTheme.colors.mutedText)
                        }
                        if (command.keys.isNotEmpty()) {
                            Text(command.keys, style = TaktTheme.type.monoSmall, color = TaktTheme.colors.mutedText)
                        }
                    }
                }
                if (matches.isEmpty()) {
                    item(key = "none", contentType = "empty") {
                        Text(
                            "No command matches",
                            style = TaktTheme.type.small, color = TaktTheme.colors.mutedText,
                            modifier = Modifier.padding(Metrics.lg),
                        )
                    }
                }
            }
        }
    }
}
