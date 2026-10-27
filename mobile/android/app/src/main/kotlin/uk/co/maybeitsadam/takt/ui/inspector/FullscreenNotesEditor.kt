package uk.co.maybeitsadam.takt.ui.inspector

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import uk.co.maybeitsadam.takt.ui.components.PButton
import uk.co.maybeitsadam.takt.ui.components.TaktTopBar
import uk.co.maybeitsadam.takt.ui.theme.Metrics
import uk.co.maybeitsadam.takt.ui.theme.TaktTheme

/**
 * A distraction-free fullscreen text editor for a task's notes.
 */
@Composable
fun FullscreenNotesEditor(
    taskTitle: String?,
    notes: String,
    onNotesChange: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val focusRequester = remember { FocusRequester() }
    val wordCount = remember(notes) {
        val trimmed = notes.trim()
        if (trimmed.isEmpty()) 0 else trimmed.split("\\s+".toRegex()).size
    }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Column(
            Modifier
                .fillMaxSize()
                .background(TaktTheme.colors.paper)
                .systemBarsPadding()
                .imePadding()
                .testTag("fullscreen_notes_editor"),
        ) {
            TaktTopBar(
                title = "Notes",
                subtitle = taskTitle?.ifBlank { null },
                showHistory = false,
                insetStatusBar = false,
            ) {
                if (wordCount > 0) {
                    Text(
                        "$wordCount ${if (wordCount == 1) "word" else "words"}",
                        style = TaktTheme.type.monoSmall,
                        color = TaktTheme.colors.dimText,
                        modifier = Modifier.padding(end = Metrics.sm),
                    )
                }
                PButton(
                    text = "Done",
                    onClick = onDismiss,
                    modifier = Modifier.testTag("notes_done"),
                )
            }

            Box(
                Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .padding(horizontal = Metrics.lg, vertical = Metrics.md),
            ) {
                if (notes.isEmpty()) {
                    Text(
                        "Add notes…",
                        style = TaktTheme.type.body,
                        color = TaktTheme.colors.dimText,
                    )
                }
                BasicTextField(
                    value = notes,
                    onValueChange = onNotesChange,
                    modifier = Modifier
                        .fillMaxSize()
                        .focusRequester(focusRequester)
                        .testTag("fullscreen_notes_text"),
                    textStyle = TaktTheme.type.body.copy(color = TaktTheme.colors.ink),
                    cursorBrush = SolidColor(TaktTheme.colors.ink),
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
                )
            }
        }
    }

    LaunchedEffect(Unit) {
        focusRequester.requestFocus()
    }
}
