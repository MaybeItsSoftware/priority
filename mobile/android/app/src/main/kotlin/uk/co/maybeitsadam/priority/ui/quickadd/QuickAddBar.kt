package uk.co.maybeitsadam.priority.ui.quickadd

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import uk.co.maybeitsadam.priority.ui.navigation.LocalShell
import uk.co.maybeitsadam.priority.ui.theme.Chalk
import uk.co.maybeitsadam.priority.ui.theme.Metrics

/**
 * The inline capture field other screens place under their header: a 48dp
 * field with a leading add icon and the parsed tokens as chips at its end.
 * Enter files into [listId] (null: the Inbox), under [parentTaskId] if given,
 * clears the field and keeps focus for the next one.
 */
@Composable
fun QuickAddBar(listId: String?, modifier: Modifier = Modifier, parentTaskId: String? = null) {
    val container = LocalShell.current.container
    val session by container.session.collectAsStateWithLifecycle()
    val colors = Chalk.colors
    var text by rememberSaveable(listId, parentTaskId) { mutableStateOf("") }
    val preview by remember { derivedStateOf { CapturePreview.of(text) } }
    val interaction = remember { MutableInteractionSource() }
    val focused by interaction.collectIsFocusedAsState()
    val target = listId ?: session?.inboxId

    fun submit() {
        val destination = target ?: return
        if (!preview.canAdd) return
        val captured = text
        container.undo.perform { it.createTask(capturing = captured, listId = destination, parentTaskId = parentTaskId) }
        text = ""
    }

    BasicTextField(
        value = text,
        onValueChange = { text = it.replace("\n", " ") },
        singleLine = true,
        textStyle = Chalk.type.body.copy(color = colors.ink),
        cursorBrush = SolidColor(colors.primary),
        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Done),
        // Done adds and keeps the keyboard up for the next task.
        keyboardActions = KeyboardActions(onDone = { submit() }),
        interactionSource = interaction,
        modifier = modifier
            .fillMaxWidth()
            .onPreviewKeyEvent { event ->
                val enter = event.key == Key.Enter || event.key == Key.NumPadEnter
                if (enter && event.type == KeyEventType.KeyDown) {
                    submit()
                    true
                } else {
                    enter
                }
            }
            .semantics { contentDescription = if (listId == null) "Add a task to the Inbox" else "Add a task" }
            .testTag("quick_add_bar"),
        decorationBox = { inner ->
            Row(
                Modifier
                    .fillMaxWidth()
                    .height(Metrics.touchTarget)
                    .clip(Metrics.control)
                    .background(colors.raised)
                    .border(BorderStroke(Metrics.hairline, if (focused) colors.primary else colors.inputBorder), Metrics.control)
                    .padding(start = Metrics.md, end = Metrics.sm),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Metrics.sm),
            ) {
                Icon(Icons.Filled.Add, null, tint = if (focused) colors.primary else colors.mutedText, modifier = Modifier.size(20.dp))
                Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                    if (text.isEmpty()) {
                        Text(
                            if (parentTaskId != null) "Add a subtask" else "Add a task",
                            style = Chalk.type.body,
                            color = colors.dimText,
                            maxLines = 1,
                        )
                    }
                    inner()
                }
                if (preview.chips.isNotEmpty()) {
                    CaptureChipRow(preview, Modifier.widthIn(max = 200.dp).testTag("quick_add_bar_chips"))
                }
            }
        },
    )
}
