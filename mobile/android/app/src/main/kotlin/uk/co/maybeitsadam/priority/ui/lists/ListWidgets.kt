package uk.co.maybeitsadam.priority.ui.lists

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.BasicAlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MenuDefaults
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.collections.immutable.ImmutableList
import uk.co.maybeitsadam.priority.ui.components.Hairline
import uk.co.maybeitsadam.priority.ui.components.PButton
import uk.co.maybeitsadam.priority.ui.theme.Chalk
import uk.co.maybeitsadam.priority.ui.theme.Metrics
import uk.co.maybeitsadam.priority.ui.theme.PIcons

/** Icons this slice needs beyond the shared set. */
internal object ListIcons {
    val Pin by lazy { PIcons.icon("Pin", "M16,9V4h1c0.55,0 1,-0.45 1,-1s-0.45,-1 -1,-1H7C6.45,2 6,2.45 6,3s0.45,1 1,1h1v5c0,1.66 -1.34,3 -3,3v2h5.97v7l1,1 1,-1v-7H19v-2c-1.66,0 -3,-1.34 -3,-3z") }
    val Everything by lazy { PIcons.icon("Everything", "M3,3h18v4H3zM3,10h18v4H3zM3,17h18v4H3z") }
    val Nested by lazy { PIcons.icon("Nested", "M4,5h2v2H4zM9,5h11v2H9zM8,11h2v2H8zM13,11h7v2h-7zM8,17h2v2H8zM13,17h7v2h-7z") }
    val Restore by lazy { PIcons.icon("Restore", "M13,3c-4.97,0 -9,4.03 -9,9H1l4,4 4,-4H6c0,-3.87 3.13,-7 7,-7s7,3.13 7,7 -3.13,7 -7,7c-1.93,0 -3.68,-0.79 -4.94,-2.06l-1.42,1.42C8.27,19.99 10.51,21 13,21c4.97,0 9,-4.03 9,-9s-4.03,-9 -9,-9z") }
}

/** A flat dropdown: raised fill, a hairline, 8dp corners, no elevation. */
@Composable
internal fun PMenu(
    expanded: Boolean,
    onDismiss: () -> Unit,
    offset: DpOffset = DpOffset(0.dp, 0.dp),
    content: @Composable ColumnScope.() -> Unit,
) {
    DropdownMenu(
        expanded = expanded,
        onDismissRequest = onDismiss,
        offset = offset,
        shape = Metrics.card,
        containerColor = Chalk.colors.raised,
        tonalElevation = 0.dp,
        shadowElevation = 0.dp,
        border = BorderStroke(Metrics.hairline, Chalk.colors.border),
        content = content,
    )
}

@Composable
internal fun PMenuItem(
    text: String,
    icon: ImageVector? = null,
    destructive: Boolean = false,
    enabled: Boolean = true,
    trailing: String? = null,
    onClick: () -> Unit,
) {
    val color = if (destructive) Chalk.colors.danger else Chalk.colors.ink
    DropdownMenuItem(
        text = { Text(text, style = Chalk.type.body, color = if (enabled) color else Chalk.colors.dimText) },
        onClick = onClick,
        enabled = enabled,
        leadingIcon = icon?.let { { Icon(it, null, tint = if (destructive) Chalk.colors.danger else Chalk.colors.mutedText, modifier = Modifier.size(18.dp)) } },
        trailingIcon = trailing?.let { { Text(it, style = Chalk.type.monoSmall, color = Chalk.colors.dimText) } },
        colors = MenuDefaults.itemColors(),
        modifier = Modifier.heightIn(min = Metrics.touchTarget),
    )
}

@Composable
internal fun PMenuDivider() {
    Hairline(Modifier.padding(vertical = Metrics.xs))
}

/** A small flat dialog: raised card, hairline, title, body, buttons on the right. */
@Composable
internal fun PDialog(
    title: String,
    onDismiss: () -> Unit,
    buttons: @Composable () -> Unit,
    body: @Composable ColumnScope.() -> Unit,
) {
    BasicAlertDialog(onDismissRequest = onDismiss) {
        Column(
            Modifier
                .clip(Metrics.card)
                .background(Chalk.colors.raised)
                .border(BorderStroke(Metrics.hairline, Chalk.colors.border), Metrics.card)
                .padding(Metrics.lg),
            verticalArrangement = Arrangement.spacedBy(Metrics.md),
        ) {
            Text(title, style = Chalk.type.heading, color = Chalk.colors.ink)
            body()
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Metrics.sm, Alignment.End)) { buttons() }
        }
    }
}

/** A single-line field in the house style: 16sp (no iOS-style zoom on Android either), 6dp, hairline. */
@Composable
internal fun PTextField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
    imeAction: ImeAction = ImeAction.Done,
    onSubmit: () -> Unit = {},
) {
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        singleLine = true,
        textStyle = Chalk.type.body.copy(fontSize = 16.sp, color = Chalk.colors.ink),
        cursorBrush = SolidColor(Chalk.colors.primary),
        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = imeAction),
        keyboardActions = KeyboardActions(onAny = { onSubmit() }),
        modifier = modifier,
        decorationBox = { inner ->
            Box(
                Modifier
                    .fillMaxWidth()
                    .heightIn(min = Metrics.touchTarget)
                    .clip(Metrics.control)
                    .background(Chalk.colors.paper)
                    .border(BorderStroke(Metrics.hairline, Chalk.colors.inputBorder), Metrics.control)
                    .padding(horizontal = Metrics.md),
                contentAlignment = Alignment.CenterStart,
            ) {
                if (value.isEmpty()) Text(placeholder, style = Chalk.type.body.copy(fontSize = 16.sp), color = Chalk.colors.dimText)
                inner()
            }
        },
    )
}

/** Asks for a name: new list, new folder, rename, new column, new list for a move. */
@Composable
internal fun NamePromptDialog(
    title: String,
    initial: String = "",
    confirm: String = "Save",
    placeholder: String = "Name",
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    var text by remember { mutableStateOf(initial) }
    val focus = remember { FocusRequester() }
    val submit = {
        if (text.isNotBlank()) {
            onConfirm(text.trim())
            onDismiss()
        }
    }
    PDialog(
        title = title,
        onDismiss = onDismiss,
        buttons = {
            PButton("Cancel", onClick = onDismiss)
            PButton(confirm, primary = true, enabled = text.isNotBlank(), onClick = submit)
        },
    ) {
        PTextField(text, { text = it }, placeholder, Modifier.fillMaxWidth().focusRequester(focus).testTag("name_prompt_field"), onSubmit = submit)
    }
    LaunchedEffect(Unit) { focus.requestFocus() }
}

@Composable
internal fun ConfirmDialog(
    title: String,
    message: String,
    confirm: String = "Delete",
    destructive: Boolean = true,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    PDialog(
        title = title,
        onDismiss = onDismiss,
        buttons = {
            PButton("Cancel", onClick = onDismiss)
            PButton(confirm, primary = true, destructive = destructive, onClick = {
                onConfirm()
                onDismiss()
            })
        },
    ) {
        Text(message, style = Chalk.type.body, color = Chalk.colors.mutedText)
    }
}

/** One choice in a picker sheet. */
@Immutable
data class Choice(
    val id: String?,
    val title: String,
    val detail: String? = null,
    val depth: Int = 0,
    val icon: ImageVector? = null,
    val isCurrent: Boolean = false,
    val tint: Color? = null,
)

/** A bottom sheet of choices: a folder, a list, a column, a quadrant. */
@Composable
internal fun ChoiceSheet(
    title: String,
    choices: ImmutableList<Choice>,
    onDismiss: () -> Unit,
    leading: (@Composable () -> Unit)? = null,
    onChoose: (Choice) -> Unit,
) {
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = false)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = state,
        containerColor = Chalk.colors.raised,
        tonalElevation = 0.dp,
        shape = Metrics.card,
    ) {
        Column(Modifier.navigationBarsPadding().imePadding()) {
            Text(title, style = Chalk.type.heading, color = Chalk.colors.ink, modifier = Modifier.padding(horizontal = Metrics.lg, vertical = Metrics.sm))
            Hairline()
            leading?.invoke()
            LazyColumn(Modifier.fillMaxWidth().testTag("choice_sheet")) {
                items(choices, key = { "${it.id}:${it.title}" }, contentType = { "choice" }) { choice ->
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .heightIn(min = Metrics.touchTarget)
                            .clickable(enabled = !choice.isCurrent, role = Role.Button) {
                                onChoose(choice)
                                onDismiss()
                            }
                            .padding(start = Metrics.lg + Metrics.indent * choice.depth, end = Metrics.lg),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        if (choice.icon != null) {
                            Icon(choice.icon, null, tint = choice.tint ?: Chalk.colors.mutedText, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(Metrics.md))
                        }
                        Column(Modifier.weight(1f)) {
                            Text(
                                choice.title, style = Chalk.type.body,
                                color = if (choice.isCurrent) Chalk.colors.dimText else Chalk.colors.ink,
                                maxLines = 1, overflow = TextOverflow.Ellipsis,
                            )
                            if (choice.detail != null) Text(choice.detail, style = Chalk.type.small, color = Chalk.colors.mutedText, maxLines = 1)
                        }
                        if (choice.isCurrent) Text("Current", style = Chalk.type.small, color = Chalk.colors.dimText)
                    }
                }
            }
        }
    }
}
