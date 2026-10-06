package uk.co.maybeitsadam.takt.ui.settings

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import kotlinx.coroutines.delay
import uk.co.maybeitsadam.takt.app.CelebrationStyle
import uk.co.maybeitsadam.takt.core.TaskStatus
import uk.co.maybeitsadam.takt.ui.components.PButton
import uk.co.maybeitsadam.takt.ui.lists.CelebratedCheck
import uk.co.maybeitsadam.takt.ui.lists.ListViewModel
import uk.co.maybeitsadam.takt.ui.lists.TaskTitle
import uk.co.maybeitsadam.takt.ui.theme.Metrics

/**
 * A sample row that plays [style] the way a real completion does: the same
 * tick and title the outline draws, flipped to completed, and for Fold taken
 * out after the same pause. It plays whenever [play] changes (choosing a
 * style, or Preview) and when its tick is tapped, then resets itself, like
 * the Mac's `CelebrationPreview`.
 */
@Composable
internal fun CelebrationPreview(style: CelebrationStyle, play: Int, onPreview: () -> Unit) {
    var status by remember { mutableStateOf(TaskStatus.OPEN) }
    var shown by remember { mutableStateOf(true) }
    var runs by remember { mutableStateOf(0) }
    // Choosing a style saves it and plays it at once; the saved choice arrives a moment later.
    val current by rememberUpdatedState(style)
    LaunchedEffect(play, runs) {
        if (play == 0 && runs == 0) return@LaunchedEffect
        // Start from an open row, so the transition the row watches for happens.
        status = TaskStatus.OPEN
        shown = true
        delay(START_DELAY_MILLIS)
        status = TaskStatus.COMPLETED
        if (current == CelebrationStyle.FOLD) {
            delay(ListViewModel.FOLD_DELAY_MILLIS)
            shown = false
        }
        delay(RESET_DELAY_MILLIS)
        shown = true
        status = TaskStatus.OPEN
    }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = Metrics.md, vertical = Metrics.sm),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Metrics.sm),
    ) {
        Box(Modifier.weight(1f).heightIn(min = Metrics.touchTarget), contentAlignment = Alignment.CenterStart) {
            SampleRow(shown, status, style) { runs += 1 }
        }
        PButton("Preview", Modifier.testTag("settings_celebration_preview"), onClick = onPreview)
    }
}

@Composable
private fun SampleRow(shown: Boolean, status: TaskStatus, style: CelebrationStyle, onToggle: () -> Unit) {
    AnimatedVisibility(
        visible = shown,
        enter = expandVertically() + fadeIn(),
        exit = shrinkVertically() + fadeOut(),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.testTag("settings_celebration_sample")) {
            CelebratedCheck(status, isList = false, title = SAMPLE_TITLE, celebration = style, onToggle = onToggle)
            TaskTitle(SAMPLE_TITLE, status, style, Modifier.weight(1f), maxLines = 1)
        }
    }
}

private const val SAMPLE_TITLE = "Water the plants"
private const val START_DELAY_MILLIS = 120L
private const val RESET_DELAY_MILLIS = 1_400L
