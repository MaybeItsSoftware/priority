package uk.co.maybeitsadam.takt.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import uk.co.maybeitsadam.takt.ui.theme.Metrics
import uk.co.maybeitsadam.takt.ui.theme.TaktTheme

/** What a swipe does: the words and glyph behind the row, in [tint]. */
data class SwipeAction(val label: String, val icon: ImageVector, val tint: Color, val run: () -> Unit)

/**
 * A row the thumb can act on, the same on every surface (docs/mobile-ux.md):
 * swiping right ([start]) completes, swiping left ([end]) schedules. The row
 * springs back after either, since the list redraws itself from the write; a
 * tick of haptics marks the threshold, a confirm the action.
 */
@Composable
fun SwipeRow(
    start: SwipeAction?,
    end: SwipeAction?,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val state = rememberSwipeToDismissBoxState()
    val scope = rememberCoroutineScope()
    val haptics = LocalHapticFeedback.current
    LaunchedEffect(state.targetValue) {
        if (state.targetValue != SwipeToDismissBoxValue.Settled) haptics.performHapticFeedback(HapticFeedbackType.GestureThresholdActivate)
    }
    SwipeToDismissBox(
        state = state,
        modifier = modifier,
        enableDismissFromStartToEnd = start != null,
        enableDismissFromEndToStart = end != null,
        backgroundContent = {
            when (state.dismissDirection) {
                SwipeToDismissBoxValue.StartToEnd -> start?.let { SwipeBackground(it, Alignment.CenterStart) }
                SwipeToDismissBoxValue.EndToStart -> end?.let { SwipeBackground(it, Alignment.CenterEnd) }
                SwipeToDismissBoxValue.Settled -> Unit
            }
        },
        onDismiss = { value ->
            val action = when (value) {
                SwipeToDismissBoxValue.StartToEnd -> start
                SwipeToDismissBoxValue.EndToStart -> end
                SwipeToDismissBoxValue.Settled -> null
            }
            if (action != null) {
                haptics.performHapticFeedback(HapticFeedbackType.Confirm)
                action.run()
            }
            scope.launch { state.reset() }
        },
    ) { content() }
}

/** The action's hue at low alpha over the paper, its glyph and word in full: tinted, not solid. */
@Composable
private fun SwipeBackground(action: SwipeAction, alignment: Alignment) {
    Box(
        Modifier
            .fillMaxSize()
            .background(TaktTheme.colors.paper)
            .background(action.tint.copy(alpha = 0.14f))
            .padding(horizontal = Metrics.lg),
        contentAlignment = alignment,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Metrics.xs + Metrics.xxs)) {
            Icon(action.icon, null, tint = action.tint, modifier = Modifier.size(18.dp))
            Text(action.label, style = TaktTheme.type.label, color = action.tint)
        }
    }
}
