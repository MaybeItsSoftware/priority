package uk.co.maybeitsadam.takt.ui.quickadd

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
import uk.co.maybeitsadam.takt.ui.components.Tag
import uk.co.maybeitsadam.takt.ui.components.priorityColor
import uk.co.maybeitsadam.takt.ui.theme.Metrics
import uk.co.maybeitsadam.takt.ui.theme.TaktTheme
import uk.co.maybeitsadam.takt.ui.theme.PIcons

/** A token's colour: the estimate is neutral, the due day azure, tags purple, priority its own hue. */
@Composable
fun captureChipColor(chip: CaptureChip): Color = when (chip.kind) {
    CaptureChipKind.ESTIMATE -> TaktTheme.colors.mutedText
    CaptureChipKind.DUE -> TaktTheme.colors.primary
    CaptureChipKind.TAG -> TaktTheme.colors.categoricalPurple
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
