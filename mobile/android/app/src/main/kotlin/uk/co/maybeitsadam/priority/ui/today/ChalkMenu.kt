package uk.co.maybeitsadam.priority.ui.today

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.heightIn
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MenuDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import uk.co.maybeitsadam.priority.ui.theme.Chalk
import uk.co.maybeitsadam.priority.ui.theme.Metrics

/** A flat dropdown: raised, a hairline border, 8dp corners, no shadow or tonal tint. */
@Composable
fun ChalkMenu(expanded: Boolean, onDismiss: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    DropdownMenu(
        expanded = expanded,
        onDismissRequest = onDismiss,
        shape = Metrics.card,
        containerColor = Chalk.colors.raised,
        tonalElevation = 0.dp,
        shadowElevation = 0.dp,
        border = BorderStroke(Metrics.hairline, Chalk.colors.border),
        content = content,
    )
}

/** One row of a [ChalkMenu]; [destructive] colours it raspberry. */
@Composable
fun ChalkMenuItem(text: String, destructive: Boolean = false, enabled: Boolean = true, onClick: () -> Unit) {
    DropdownMenuItem(
        text = { Text(text, style = Chalk.type.body) },
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.heightIn(min = Metrics.touchTarget),
        colors = MenuDefaults.itemColors(
            textColor = if (destructive) Chalk.colors.danger else Chalk.colors.ink,
            disabledTextColor = Chalk.colors.dimText,
        ),
    )
}
