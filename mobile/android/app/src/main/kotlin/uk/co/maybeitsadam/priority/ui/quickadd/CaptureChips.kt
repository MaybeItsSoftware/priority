package uk.co.maybeitsadam.priority.ui.quickadd

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.rememberScrollState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp
import uk.co.maybeitsadam.priority.ui.components.Tag
import uk.co.maybeitsadam.priority.ui.components.priorityColor
import uk.co.maybeitsadam.priority.ui.theme.Metrics
import uk.co.maybeitsadam.priority.ui.theme.PriorityTheme
import uk.co.maybeitsadam.priority.ui.theme.PIcons

/** A token's colour: the estimate is neutral, the due day azure, tags purple, priority its own hue. */
@Composable
fun captureChipColor(chip: CaptureChip): Color = when (chip.kind) {
    CaptureChipKind.ESTIMATE -> PriorityTheme.colors.mutedText
    CaptureChipKind.DUE -> PriorityTheme.colors.primary
    CaptureChipKind.TAG -> PriorityTheme.colors.categoricalPurple
    CaptureChipKind.PRIORITY -> priorityColor(chip.priority)
}

/** The found tokens as squarish chips, read aloud as one sentence. */
@Composable
fun CaptureChipRow(preview: CapturePreview, modifier: Modifier = Modifier) {
    Row(
        modifier
            .horizontalScroll(rememberScrollState())
            .clearAndSetSemantics { contentDescription = preview.spoken },
        horizontalArrangement = Arrangement.spacedBy(Metrics.xs),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        for (chip in preview.chips) {
            Tag(
                chip.label,
                color = captureChipColor(chip),
                mono = chip.kind == CaptureChipKind.ESTIMATE || chip.kind == CaptureChipKind.PRIORITY,
                leading = when (chip.kind) {
                    CaptureChipKind.ESTIMATE -> PIcons.Timer
                    CaptureChipKind.DUE -> PIcons.Calendar
                    else -> null
                },
            )
        }
    }
}
