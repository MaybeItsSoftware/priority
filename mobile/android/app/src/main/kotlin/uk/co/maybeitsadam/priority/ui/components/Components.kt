package uk.co.maybeitsadam.priority.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Settings
import uk.co.maybeitsadam.priority.ui.theme.PIcons
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import uk.co.maybeitsadam.priority.core.TaskStatus
import uk.co.maybeitsadam.priority.ui.navigation.LocalShell
import uk.co.maybeitsadam.priority.ui.theme.Chalk
import uk.co.maybeitsadam.priority.ui.theme.Metrics

/** A 1dp rule in the border colour: the app's only means of separation. */
@Composable
fun Hairline(modifier: Modifier = Modifier, color: Color = Chalk.colors.border) {
    Box(modifier.fillMaxWidth().height(Metrics.hairline).background(color))
}

@Composable
fun VerticalHairline(modifier: Modifier = Modifier, color: Color = Chalk.colors.border) {
    Box(modifier.fillMaxHeight().width(Metrics.hairline).background(color))
}

/**
 * The header band every screen starts with: one height across panes, a title,
 * an optional muted subtitle, trailing actions, and a hairline beneath. It
 * pads itself below the status bar, so screens draw edge to edge.
 */
@Composable
fun PriorityTopBar(
    title: String,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    navigation: (@Composable () -> Unit)? = null,
    showHistory: Boolean = true,
    insetStatusBar: Boolean = true,
    actions: @Composable RowScope.() -> Unit = {},
) {
    Column(
        modifier
            .fillMaxWidth()
            .background(Chalk.colors.paper)
            .then(if (insetStatusBar) Modifier.windowInsetsPadding(WindowInsets.statusBars.only(WindowInsetsSides.Top)) else Modifier),
    ) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = Metrics.headerHeight).padding(start = if (navigation == null) Metrics.lg else Metrics.xs, end = Metrics.xs),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            navigation?.invoke()
            Column(Modifier.weight(1f).padding(vertical = Metrics.xs)) {
                Text(title, style = Chalk.type.title, color = Chalk.colors.ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (subtitle != null) {
                    Text(subtitle, style = Chalk.type.small, color = Chalk.colors.mutedText, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            actions()
            if (showHistory) HistoryActions()
        }
        Hairline()
    }
}

/** Toolbar undo, redo and the history sheet, labelled with what each would do. */
@Composable
fun HistoryActions() {
    val shell = LocalShell.current
    val labels by shell.container.undo.labels.collectAsStateWithLifecycle()
    IconAction(
        PIcons.Undo,
        labels.undo?.let { "Undo $it" } ?: "Nothing to undo",
        enabled = labels.undo != null,
        onClick = { shell.container.undo.undo() },
    )
    IconAction(
        PIcons.Redo,
        labels.redo?.let { "Redo $it" } ?: "Nothing to redo",
        enabled = labels.redo != null,
        onClick = { shell.container.undo.redo() },
    )
    IconAction(PIcons.History, "History", onClick = { shell.showHistory() })
}

/** A 48dp icon button with no fill: the toolbar's only button style. */
@Composable
fun IconAction(
    icon: ImageVector,
    contentDescription: String,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    tint: Color = Chalk.colors.mutedText,
    onClick: () -> Unit,
) {
    IconButton(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier.size(Metrics.touchTarget),
        colors = IconButtonDefaults.iconButtonColors(contentColor = tint, disabledContentColor = Chalk.colors.dimText),
    ) {
        Icon(icon, contentDescription = contentDescription, modifier = Modifier.size(20.dp))
    }
}

/** The settings gear for a top bar. */
@Composable
fun SettingsAction() {
    val shell = LocalShell.current
    IconAction(Icons.Filled.Settings, "Settings", onClick = { shell.navigator.openSettings() })
}

/** A sentence-case muted label over a section, with an optional trailing control. */
@Composable
fun SectionHeader(
    text: String,
    modifier: Modifier = Modifier,
    detail: String? = null,
    trailing: (@Composable () -> Unit)? = null,
) {
    Row(
        modifier.fillMaxWidth().heightIn(min = 36.dp).padding(horizontal = Metrics.lg),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(text, style = Chalk.type.label, color = Chalk.colors.mutedText, modifier = Modifier.weight(1f, fill = false))
        if (detail != null) {
            Spacer(Modifier.width(Metrics.sm))
            Text(detail, style = Chalk.type.monoSmall, color = Chalk.colors.dimText)
        }
        Spacer(Modifier.weight(1f))
        trailing?.invoke()
    }
}

/**
 * A squarish 6dp tag: tinted fill, border and text of one hue, never a capsule.
 * [selected] fills it a little more; [onClick] makes it a 48dp-tall target.
 */
@Composable
fun Tag(
    text: String,
    modifier: Modifier = Modifier,
    color: Color = Chalk.colors.mutedText,
    selected: Boolean = false,
    mono: Boolean = false,
    leading: ImageVector? = null,
    onClick: (() -> Unit)? = null,
) {
    val shape = Metrics.control
    val fill = if (selected) color.copy(alpha = 0.18f) else color.copy(alpha = 0.08f)
    val border = if (selected) color.copy(alpha = 0.7f) else color.copy(alpha = 0.35f)
    val content = @Composable {
        Row(
            Modifier
                .clip(shape)
                .background(fill)
                .border(BorderStroke(Metrics.hairline, border), shape)
                .padding(horizontal = 8.dp, vertical = 3.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            if (leading != null) Icon(leading, null, tint = color, modifier = Modifier.size(14.dp))
            Text(text, style = if (mono) Chalk.type.monoSmall.copy(fontSize = Chalk.type.small.fontSize) else Chalk.type.small, color = if (color == Chalk.colors.mutedText) Chalk.colors.ink else color, maxLines = 1)
        }
    }
    if (onClick == null) {
        Box(modifier) { content() }
    } else {
        Box(
            modifier
                .sizeIn(minHeight = Metrics.touchTarget)
                .clip(shape)
                .clickable(role = Role.Button, onClick = onClick),
            contentAlignment = Alignment.Center,
        ) { content() }
    }
}

/** A flat button: filled primary for the main action, bordered otherwise. 6dp, 48dp tall, no elevation. */
@Composable
fun PButton(
    text: String,
    modifier: Modifier = Modifier,
    primary: Boolean = false,
    destructive: Boolean = false,
    enabled: Boolean = true,
    icon: ImageVector? = null,
    contentPadding: PaddingValues = PaddingValues(horizontal = Metrics.md),
    onClick: () -> Unit,
) {
    val colors = Chalk.colors
    val accent = if (destructive) colors.danger else colors.primary
    val fill = when {
        !enabled -> colors.well
        primary -> accent
        else -> colors.raised
    }
    val textColor = when {
        !enabled -> colors.dimText
        primary -> colors.onAccent
        destructive -> colors.danger
        else -> colors.ink
    }
    Row(
        modifier
            .heightIn(min = Metrics.touchTarget)
            .clip(Metrics.control)
            .background(fill)
            .border(BorderStroke(Metrics.hairline, if (primary && enabled) accent else colors.inputBorder), Metrics.control)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(contentPadding),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
    ) {
        if (icon != null) Icon(icon, null, tint = textColor, modifier = Modifier.size(18.dp))
        Text(text, style = Chalk.type.bodyStrong.copy(fontSize = Chalk.type.small.fontSize.times(1.05f)), color = textColor, maxLines = 1)
    }
}

/** A quiet centred message for an empty screen or section. */
@Composable
fun EmptyState(title: String, modifier: Modifier = Modifier, detail: String? = null, action: (@Composable () -> Unit)? = null) {
    Column(
        modifier.fillMaxWidth().padding(horizontal = Metrics.xl, vertical = 40.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Metrics.sm),
    ) {
        Text(title, style = Chalk.type.heading, color = Chalk.colors.ink)
        if (detail != null) Text(detail, style = Chalk.type.small, color = Chalk.colors.mutedText)
        action?.invoke()
    }
}

/**
 * The task's tick: an outlined circle when open, an emerald disc with a check
 * when done, a raspberry disc with a cross when cancelled. The painted circle
 * is 20dp; the target around it is 48dp.
 */
@Composable
fun TaskCheck(
    status: TaskStatus,
    modifier: Modifier = Modifier,
    isList: Boolean = false,
    size: Dp = 20.dp,
    /** The task's title, so the action reads "Complete Write report" to TalkBack and tests. */
    label: String? = null,
    onToggle: () -> Unit,
) {
    val colors = Chalk.colors
    val verb = when (status) {
        TaskStatus.OPEN -> "Complete"
        TaskStatus.COMPLETED -> "Reopen"
        TaskStatus.CANCELLED -> "Reinstate"
    }
    val description = if (label == null) verb else "$verb $label"
    Box(
        modifier
            .size(Metrics.touchTarget)
            .clip(CircleShape)
            .clickable(role = Role.Checkbox, onClick = onToggle)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        val shape = if (isList) Metrics.control else CircleShape
        when (status) {
            TaskStatus.OPEN -> Box(Modifier.size(size).border(BorderStroke(1.5.dp, colors.inputBorder), shape))
            TaskStatus.COMPLETED -> Box(Modifier.size(size).clip(shape).background(colors.success), contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.Check, null, tint = colors.onAccent, modifier = Modifier.size(size * 0.7f))
            }
            TaskStatus.CANCELLED -> Box(Modifier.size(size).clip(shape).background(colors.danger), contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.Close, null, tint = colors.onAccent, modifier = Modifier.size(size * 0.7f))
            }
        }
    }
}

/** `!1` … `!4`, coloured raspberry, amber, azure, muted. */
@Composable
fun priorityColor(priority: Int?): Color = when (priority) {
    1 -> Chalk.colors.danger
    2 -> Chalk.colors.warning
    3 -> Chalk.colors.primary
    else -> Chalk.colors.mutedText
}

/** A raised card: white on paper, a hairline border, 8dp corners, no shadow. */
@Composable
fun Card(modifier: Modifier = Modifier, selected: Boolean = false, content: @Composable () -> Unit) {
    Box(
        modifier
            .clip(Metrics.card)
            .background(Chalk.colors.raised)
            .border(BorderStroke(Metrics.hairline, if (selected) Chalk.colors.primary else Chalk.colors.border), Metrics.card),
    ) { content() }
}

/** Monospaced numbers: counts, clocks, estimates. */
@Composable
fun MonoText(text: String, modifier: Modifier = Modifier, style: TextStyle = Chalk.type.mono, color: Color = Chalk.colors.mutedText) {
    Text(text, modifier = modifier, style = style, color = color, maxLines = 1)
}
