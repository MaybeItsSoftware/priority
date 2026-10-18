package uk.co.maybeitsadam.takt.watch.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import androidx.wear.compose.material3.Text

/** The time, ticking each second while [active] and the screen is visible; otherwise read once. */
@Composable
fun rememberNow(active: Boolean): State<Long> {
    val now = remember { mutableLongStateOf(System.currentTimeMillis()) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(active, lifecycle) {
        now.longValue = System.currentTimeMillis()
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                now.longValue = System.currentTimeMillis()
                // Each minute while idle, so the snapshot's age moves on too.
                val period = if (active) 1_000L else 60_000L
                delay(period - System.currentTimeMillis() % period)
            }
        }
    }
    return now
}

/** A small heading in sentence case, muted: what a group of rows is. */
@Composable
fun Caption(text: String, modifier: Modifier = Modifier, color: Color = WatchColors.muted) {
    Text(
        text, modifier = modifier.padding(horizontal = 8.dp), color = color, fontSize = 12.sp,
        fontWeight = FontWeight.Medium, textAlign = TextAlign.Center, maxLines = 1,
    )
}

/**
 * A button in the house style: a tint of [hue] with a border of it and its
 * text, 6dp corners, never shorter than the 48dp target.
 */
@Composable
fun TintButton(
    label: String,
    hue: Color,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    solid: Boolean = false,
) {
    val shape = RoundedCornerShape(WatchShape.control)
    Box(
        modifier
            .defaultMinSize(minHeight = WatchShape.target)
            .background(if (solid) hue else hue.copy(alpha = 0.14f), shape)
            .border(WatchShape.hairline, hue.copy(alpha = if (solid) 1f else 0.5f), shape)
            .clickable(role = Role.Button, onClickLabel = label, onClick = onClick)
            .padding(horizontal = 10.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, color = if (solid) Color.White else hue, fontSize = 15.sp, fontWeight = FontWeight.Medium, maxLines = 1)
    }
}

/** A row of buttons sharing the width. */
@Composable
fun ButtonRow(modifier: Modifier = Modifier, content: @Composable RowScope.() -> Unit) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically, content = content)
}
