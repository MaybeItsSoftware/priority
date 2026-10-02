package uk.co.maybeitsadam.priority.ui.lists

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import uk.co.maybeitsadam.priority.app.CelebrationStyle
import uk.co.maybeitsadam.priority.core.TaskStatus
import uk.co.maybeitsadam.priority.ui.components.TaskCheck
import uk.co.maybeitsadam.priority.ui.components.priorityColor
import uk.co.maybeitsadam.priority.ui.theme.Chalk
import uk.co.maybeitsadam.priority.ui.theme.Metrics
import uk.co.maybeitsadam.priority.ui.theme.PIcons

/** A disclosure chevron: "Fold <title>" when open, "Unfold <title>" when folded. */
@Composable
internal fun FoldChevron(title: String, isFolded: Boolean, onToggle: () -> Unit, modifier: Modifier = Modifier) {
    val description = if (isFolded) "Unfold $title" else "Fold $title"
    Box(
        modifier
            .width(32.dp)
            .heightIn(min = Metrics.touchTarget)
            .clickable(role = Role.Button, onClick = onToggle)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            if (isFolded) Icons.AutoMirrored.Filled.KeyboardArrowRight else Icons.Filled.KeyboardArrowDown,
            contentDescription = null,
            tint = Chalk.colors.mutedText,
            modifier = Modifier.size(18.dp),
        )
    }
}

/** The tick, with the Spark celebration drawn round it when it is newly finished. */
@Composable
internal fun CelebratedCheck(
    status: TaskStatus,
    isList: Boolean,
    title: String,
    celebration: CelebrationStyle,
    onToggle: () -> Unit,
) {
    val spark = remember { Animatable(0f) }
    var previous by remember { mutableStateOf(status) }
    LaunchedEffect(status) {
        if (previous == TaskStatus.OPEN && status == TaskStatus.COMPLETED && celebration == CelebrationStyle.SPARK) {
            spark.snapTo(0f)
            spark.animateTo(1f, tween(520))
            spark.snapTo(0f)
        }
        previous = status
    }
    val color = Chalk.colors.success
    Box(
        Modifier.drawBehind {
            val t = spark.value
            if (t > 0f) {
                val radius = 10.dp.toPx() + 16.dp.toPx() * t
                drawCircle(color.copy(alpha = (1f - t) * 0.8f), radius, style = Stroke(width = 2.dp.toPx() * (1f - t) + 0.5f))
                for (i in 0 until 6) {
                    val angle = Math.toRadians(i * 60.0 + 30.0)
                    val inner = radius * 0.7f
                    val outer = radius * 1.05f
                    drawLine(
                        color.copy(alpha = 1f - t),
                        Offset(center.x + inner * Math.cos(angle).toFloat(), center.y + inner * Math.sin(angle).toFloat()),
                        Offset(center.x + outer * Math.cos(angle).toFloat(), center.y + outer * Math.sin(angle).toFloat()),
                        strokeWidth = 1.5.dp.toPx(),
                    )
                }
            }
        },
    ) {
        TaskCheck(status, isList = isList, label = title, onToggle = onToggle)
    }
}

/**
 * The title. A closed row is muted; with Strike, Spark or Fold it also carries
 * a rule through it, drawn across when the row is newly finished.
 */
@Composable
internal fun TaskTitle(
    title: String,
    status: TaskStatus,
    celebration: CelebrationStyle,
    modifier: Modifier = Modifier,
    style: TextStyle = Chalk.type.body,
    maxLines: Int = 2,
) {
    val closed = status != TaskStatus.OPEN
    val struck = closed && celebration != CelebrationStyle.NONE
    val fraction = remember { Animatable(if (struck) 1f else 0f) }
    var previous by remember { mutableStateOf(status) }
    LaunchedEffect(status, celebration) {
        when {
            !struck -> fraction.snapTo(0f)
            previous == TaskStatus.OPEN && celebration == CelebrationStyle.STRIKE -> {
                fraction.snapTo(0f)
                fraction.animateTo(1f, tween(320))
            }
            else -> fraction.snapTo(1f)
        }
        previous = status
    }
    val ruleColor = Chalk.colors.mutedText
    Text(
        title,
        style = style,
        color = if (closed) Chalk.colors.mutedText else Chalk.colors.ink,
        maxLines = maxLines,
        overflow = TextOverflow.Ellipsis,
        modifier = modifier.drawWithContent {
            drawContent()
            val f = fraction.value
            if (f > 0f) {
                // One rule through the first line, as the Mac's strike plugin draws it.
                val y = minOf(size.height / 2f, 11.dp.toPx())
                drawLine(ruleColor, Offset(0f, y), Offset(size.width * f, y), strokeWidth = 1.dp.toPx())
            }
        },
    )
}

/** Due, estimate, priority, tags, daily and planned, compactly, after the title. */
@Composable
internal fun RowMarkers(row: OutlineRow, modifier: Modifier = Modifier, maxTags: Int = 2) {
    Row(modifier.fillMaxHeight(), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
        val colors = Chalk.colors
        if (row.isPlanned) Icon(PIcons.Today, "Planned for today", tint = colors.primary, modifier = Modifier.size(14.dp))
        if (row.isDaily) Icon(PIcons.Repeat, "Daily", tint = colors.success, modifier = Modifier.size(14.dp))
        for (tag in row.tags.take(maxTags)) {
            Text("#$tag", style = Chalk.type.small, color = colors.mutedText, maxLines = 1)
        }
        if (row.tags.size > maxTags) Text("+${row.tags.size - maxTags}", style = Chalk.type.monoSmall, color = colors.dimText)
        row.priority?.let { Text("!$it", style = Chalk.type.mono, color = priorityColor(it)) }
        row.estimate?.let { Text(it, style = Chalk.type.monoSmall, color = colors.mutedText) }
        row.due?.let { due ->
            val tint = when {
                row.status != TaskStatus.OPEN -> colors.dimText
                due.isOverdue -> colors.danger
                due.isToday -> colors.warning
                else -> colors.mutedText
            }
            Text(due.text, style = Chalk.type.monoSmall, color = tint, maxLines = 1)
        }
        if (row.hasNotes) Icon(PIcons.Notes, "Has notes", tint = colors.dimText, modifier = Modifier.size(14.dp))
    }
}
