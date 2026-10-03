package uk.co.maybeitsadam.priority.ui.review

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import uk.co.maybeitsadam.priority.ui.components.VerticalHairline
import uk.co.maybeitsadam.priority.ui.theme.Chalk
import uk.co.maybeitsadam.priority.ui.theme.Metrics

/**
 * A flat segmented control: a 6dp bordered strip, hairlines between the
 * options, the chosen one on the well tone in ink. 48dp tall.
 */
@Composable
fun <T> Segmented(
    options: List<T>,
    selected: T,
    label: (T) -> String,
    modifier: Modifier = Modifier,
    tag: (T) -> String = { "" },
    onSelect: (T) -> Unit,
) {
    Row(
        modifier
            .fillMaxWidth()
            .height(Metrics.touchTarget)
            .clip(Metrics.control)
            .border(BorderStroke(Metrics.hairline, Chalk.colors.inputBorder), Metrics.control),
    ) {
        options.forEachIndexed { index, option ->
            if (index > 0) VerticalHairline(color = Chalk.colors.inputBorder)
            val isSelected = option == selected
            Box(
                Modifier
                    .weight(1f)
                    .fillMaxHeight()
                    .background(if (isSelected) Chalk.colors.well else Chalk.colors.raised)
                    .clickable(role = Role.Tab) { onSelect(option) }
                    .semantics { this.selected = isSelected }
                    .then(tag(option).takeIf { it.isNotEmpty() }?.let { Modifier.testTag(it) } ?: Modifier),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    label(option),
                    style = if (isSelected) Chalk.type.bodyStrong.copy(fontSize = Chalk.type.small.fontSize) else Chalk.type.small,
                    color = if (isSelected) Chalk.colors.ink else Chalk.colors.mutedText,
                    maxLines = 1,
                )
            }
        }
    }
}
