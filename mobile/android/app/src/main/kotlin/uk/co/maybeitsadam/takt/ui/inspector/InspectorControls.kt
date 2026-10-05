package uk.co.maybeitsadam.takt.ui.inspector

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MenuDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import uk.co.maybeitsadam.takt.ui.components.Hairline
import uk.co.maybeitsadam.takt.ui.theme.TaktTheme
import uk.co.maybeitsadam.takt.ui.theme.Metrics

/** A block of the inspector: a sentence-case muted label, its controls, a hairline under it. */
@Composable
fun InspectorSection(
    label: String,
    modifier: Modifier = Modifier,
    detail: String? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(modifier.fillMaxWidth()) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = Metrics.lg, vertical = Metrics.md),
            verticalArrangement = Arrangement.spacedBy(Metrics.sm),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(label, style = TaktTheme.type.label, color = TaktTheme.colors.mutedText, modifier = Modifier.weight(1f))
                if (detail != null) Text(detail, style = TaktTheme.type.monoSmall, color = TaktTheme.colors.dimText)
            }
            content()
        }
        Hairline()
    }
}

/** A sub-label inside a section: smaller, still muted, still sentence case. */
@Composable
fun FieldLabel(text: String, modifier: Modifier = Modifier) {
    Text(text, style = TaktTheme.type.small, color = TaktTheme.colors.mutedText, modifier = modifier)
}

/** A line of explanation under a control. */
@Composable
fun Hint(text: String, modifier: Modifier = Modifier, color: Color = TaktTheme.colors.dimText) {
    Text(text, style = TaktTheme.type.small, color = color, modifier = modifier)
}

/**
 * The app's text field: raised fill, a 6dp hairline border that turns azure
 * when focused and raspberry on an error, 48dp tall. No Material underline.
 */
@Composable
fun ChalkField(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    placeholder: String = "",
    singleLine: Boolean = true,
    minLines: Int = 1,
    maxLines: Int = if (singleLine) 1 else Int.MAX_VALUE,
    style: TextStyle = TaktTheme.type.body,
    isError: Boolean = false,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
    leading: (@Composable () -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
    contentDescription: String? = null,
) {
    val colors = TaktTheme.colors
    val interaction = remember { MutableInteractionSource() }
    val focused by interaction.collectIsFocusedAsState()
    val borderColor = when {
        isError -> colors.danger
        focused -> colors.primary
        else -> colors.inputBorder
    }
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier
            .fillMaxWidth()
            .then(if (contentDescription != null) Modifier.semantics { this.contentDescription = contentDescription } else Modifier),
        singleLine = singleLine,
        minLines = minLines,
        maxLines = maxLines,
        textStyle = style.copy(color = colors.ink),
        cursorBrush = SolidColor(colors.primary),
        keyboardOptions = keyboardOptions,
        keyboardActions = keyboardActions,
        interactionSource = interaction,
        decorationBox = { inner ->
            Row(
                Modifier
                    .heightIn(min = Metrics.touchTarget)
                    .clip(Metrics.control)
                    .background(colors.raised)
                    .border(BorderStroke(Metrics.hairline, borderColor), Metrics.control)
                    .padding(horizontal = Metrics.md, vertical = Metrics.sm + Metrics.xxs),
                verticalAlignment = if (singleLine) Alignment.CenterVertically else Alignment.Top,
                horizontalArrangement = Arrangement.spacedBy(Metrics.sm),
            ) {
                leading?.invoke()
                Box(Modifier.weight(1f)) {
                    if (value.isEmpty() && placeholder.isNotEmpty()) {
                        Text(placeholder, style = style, color = colors.dimText, maxLines = if (singleLine) 1 else Int.MAX_VALUE)
                    }
                    inner()
                }
                trailing?.invoke()
            }
        },
    )
}

/** A whole-row switch: the label (and detail) on the left, a Chalk switch on the right. */
@Composable
fun SwitchRow(
    label: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    detail: String? = null,
    enabled: Boolean = true,
) {
    val colors = TaktTheme.colors
    Row(
        modifier
            .fillMaxWidth()
            .heightIn(min = Metrics.touchTarget)
            .clip(Metrics.control)
            .toggleable(value = checked, enabled = enabled, role = Role.Switch, onValueChange = onCheckedChange),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f).padding(vertical = Metrics.xs)) {
            Text(label, style = TaktTheme.type.body, color = if (enabled) colors.ink else colors.dimText)
            if (detail != null) Text(detail, style = TaktTheme.type.small, color = colors.mutedText)
        }
        Spacer(Modifier.width(Metrics.sm))
        Switch(
            checked = checked,
            onCheckedChange = null,
            enabled = enabled,
            colors = SwitchDefaults.colors(
                checkedThumbColor = colors.onAccent,
                checkedTrackColor = colors.primary,
                checkedBorderColor = colors.primary,
                uncheckedThumbColor = colors.mutedText,
                uncheckedTrackColor = colors.well,
                uncheckedBorderColor = colors.inputBorder,
                disabledCheckedTrackColor = colors.well,
                disabledUncheckedTrackColor = colors.well,
            ),
        )
    }
}

/** One option of a [Segmented] control. */
data class Segment<T>(val label: String, val value: T, val tint: Color? = null, val description: String? = null)

/**
 * A row of joined segments with hairline dividers. The selected one takes a
 * tinted fill and border of its own hue (azure unless the option says).
 */
@Composable
fun <T> Segmented(
    options: List<Segment<T>>,
    selected: T,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
    mono: Boolean = false,
) {
    val colors = TaktTheme.colors
    Row(
        modifier
            .fillMaxWidth()
            .heightIn(min = Metrics.touchTarget)
            .clip(Metrics.control)
            .border(BorderStroke(Metrics.hairline, colors.inputBorder), Metrics.control),
    ) {
        options.forEachIndexed { index, option ->
            if (index > 0) Box(Modifier.width(Metrics.hairline).heightIn(min = Metrics.touchTarget).background(colors.inputBorder))
            val isSelected = option.value == selected
            val tint = option.tint ?: colors.primary
            Box(
                Modifier
                    .weight(1f)
                    .heightIn(min = Metrics.touchTarget)
                    .background(if (isSelected) tint.copy(alpha = 0.14f) else colors.raised)
                    .selectable(selected = isSelected, role = Role.Tab, onClick = { onSelect(option.value) })
                    .then(if (option.description != null) Modifier.semantics { contentDescription = option.description } else Modifier),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    option.label,
                    style = if (mono) TaktTheme.type.mono else TaktTheme.type.small,
                    color = when {
                        isSelected && option.tint != null -> option.tint
                        isSelected -> colors.ink
                        else -> colors.mutedText
                    },
                    maxLines = 1,
                )
            }
        }
    }
}

/** A field-shaped button that opens a menu: the current value, a chevron. */
@Composable
fun MenuField(
    text: String,
    expanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    leading: ImageVector? = null,
    contentDescription: String? = null,
    menu: @Composable ColumnScope.() -> Unit,
) {
    val colors = TaktTheme.colors
    Box(modifier) {
        Row(
            Modifier
                .fillMaxWidth()
                .heightIn(min = Metrics.touchTarget)
                .clip(Metrics.control)
                .background(colors.raised)
                .border(BorderStroke(Metrics.hairline, if (expanded) colors.primary else colors.inputBorder), Metrics.control)
                .clickable(role = Role.DropdownList) { onExpandedChange(!expanded) }
                .then(if (contentDescription != null) Modifier.semantics { this.contentDescription = contentDescription } else Modifier)
                .padding(horizontal = Metrics.md),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Metrics.sm),
        ) {
            if (leading != null) Icon(leading, null, tint = colors.mutedText, modifier = Modifier.size(18.dp))
            Text(text, style = TaktTheme.type.body, color = colors.ink, maxLines = 1, modifier = Modifier.weight(1f))
            Icon(
                androidx.compose.material.icons.Icons.Filled.KeyboardArrowDown, null,
                tint = colors.mutedText, modifier = Modifier.size(20.dp),
            )
        }
        ChalkMenu(expanded = expanded, onDismiss = { onExpandedChange(false) }, content = menu)
    }
}

/** A dropdown with no shadow: raised fill, a hairline border, 8dp corners. */
@Composable
fun ChalkMenu(expanded: Boolean, onDismiss: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    DropdownMenu(
        expanded = expanded,
        onDismissRequest = onDismiss,
        shape = Metrics.card,
        containerColor = TaktTheme.colors.raised,
        tonalElevation = 0.dp,
        shadowElevation = 0.dp,
        border = BorderStroke(Metrics.hairline, TaktTheme.colors.border),
        content = content,
    )
}

@Composable
fun ChalkMenuItem(text: String, onClick: () -> Unit, selected: Boolean = false, modifier: Modifier = Modifier) {
    DropdownMenuItem(
        text = { Text(text, style = if (selected) TaktTheme.type.bodyStrong else TaktTheme.type.body) },
        onClick = onClick,
        modifier = modifier,
        colors = MenuDefaults.itemColors(textColor = if (selected) TaktTheme.colors.primary else TaktTheme.colors.ink),
    )
}

/** A small square button for steppers: 48dp target, 6dp hairline box. */
@Composable
fun StepButton(icon: ImageVector, description: String, modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    val colors = TaktTheme.colors
    Box(
        modifier
            .size(Metrics.touchTarget)
            .clip(Metrics.control)
            .border(BorderStroke(Metrics.hairline, colors.inputBorder), Metrics.control)
            .background(colors.raised)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, null, tint = if (enabled) colors.ink else colors.dimText, modifier = Modifier.size(18.dp))
    }
}
