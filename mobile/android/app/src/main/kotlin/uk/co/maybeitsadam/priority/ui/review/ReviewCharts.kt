package uk.co.maybeitsadam.priority.ui.review

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlinx.collections.immutable.ImmutableList
import uk.co.maybeitsadam.priority.ui.components.Card
import uk.co.maybeitsadam.priority.ui.theme.PriorityTheme
import uk.co.maybeitsadam.priority.ui.theme.Metrics

/** One line or set of bars on a chart. */
@Immutable
data class ChartSeries(val name: String, val values: ImmutableList<Double>, val color: Color)

enum class ChartKind { BARS, LINES }

private val axisDate = DateTimeFormatter.ofPattern("d MMM", Locale.ENGLISH)

/** Whole numbers without a decimal point; halves keep theirs. */
internal fun axisNumber(value: Double): String =
    if (value == Math.floor(value)) value.toLong().toString() else String.format(Locale.ROOT, "%.1f", value)

/**
 * A chart in a card: a muted title, an optional legend, and the plot drawn on
 * a Canvas — hairline grid and baseline, Lilex numbers, flat marks. No chart
 * library. [description] is what TalkBack reads instead of the marks.
 */
@Composable
fun ChartCard(
    title: String,
    description: String,
    days: ImmutableList<Instant>,
    series: ImmutableList<ChartSeries>,
    kind: ChartKind,
    modifier: Modifier = Modifier,
    testTag: String = "",
) {
    Card(modifier.fillMaxWidth()) {
        Column(Modifier.padding(Metrics.md)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(title, style = PriorityTheme.type.label, color = PriorityTheme.colors.mutedText, modifier = Modifier.weight(1f))
                if (series.size > 1) {
                    series.forEach { s ->
                        Box(Modifier.size(8.dp).background(s.color, RoundedCornerShape(2.dp)))
                        Spacer(Modifier.width(Metrics.xs))
                        Text(s.name, style = PriorityTheme.type.small, color = PriorityTheme.colors.mutedText)
                        Spacer(Modifier.width(Metrics.sm))
                    }
                }
            }
            Spacer(Modifier.height(Metrics.sm))
            Plot(
                days, series, kind,
                Modifier
                    .fillMaxWidth()
                    .height(168.dp)
                    .clearAndSetSemantics { contentDescription = description }
                    .then(if (testTag.isNotEmpty()) Modifier.testTag(testTag) else Modifier),
            )
        }
    }
}

@Composable
private fun Plot(days: ImmutableList<Instant>, series: ImmutableList<ChartSeries>, kind: ChartKind, modifier: Modifier) {
    val measurer = rememberTextMeasurer()
    val labelStyle = PriorityTheme.type.monoSmall.copy(color = PriorityTheme.colors.mutedText)
    val grid = PriorityTheme.colors.borderMuted
    val baseline = PriorityTheme.colors.border
    val zone = remember { ZoneId.systemDefault() }
    val maxValue = series.maxOfOrNull { s -> s.values.maxOrNull() ?: 0.0 } ?: 0.0
    val scale = remember(maxValue) { ChartScale.nice(maxValue) }
    val xLabels = remember(days) {
        if (days.isEmpty()) emptyList() else listOf(0, days.size / 2, days.size - 1).distinct()
            .map { it to axisDate.format(days[it].atZone(zone)) }
    }
    Canvas(modifier) {
        val gutter = 30.dp.toPx()
        val footer = 18.dp.toPx()
        val plotWidth = size.width - gutter
        val plotHeight = size.height - footer
        // Grid and value labels.
        for (tick in scale.ticks) {
            val y = plotHeight * (1 - scale.fraction(tick))
            drawLine(if (tick == 0.0) baseline else grid, Offset(gutter, y), Offset(size.width, y), strokeWidth = 1.dp.toPx())
            drawLabel(measurer, axisNumber(tick), labelStyle, Offset(gutter - 4.dp.toPx(), y), alignEnd = true)
        }
        // Day labels under the first, middle and last day.
        val count = days.size
        for ((index, text) in xLabels) {
            val (left, width) = barSlot(index, count, plotWidth)
            drawLabel(measurer, text, labelStyle, Offset(gutter + left + width / 2, plotHeight + 3.dp.toPx()), centreX = true, top = true)
        }
        when (kind) {
            ChartKind.BARS -> drawBars(series, scale, gutter, plotWidth, plotHeight)
            ChartKind.LINES -> drawLines(series, scale, gutter, plotWidth, plotHeight)
        }
    }
}

private fun DrawScope.drawBars(series: List<ChartSeries>, scale: ChartScale, left: Float, width: Float, height: Float) {
    val count = series.maxOfOrNull { it.values.size } ?: 0
    if (count == 0) return
    val groups = series.size
    for (index in 0 until count) {
        val (slotLeft, slotWidth) = barSlot(index, count, width)
        val each = slotWidth / groups
        series.forEachIndexed { g, s ->
            val value = s.values.getOrNull(index) ?: return@forEachIndexed
            if (value <= 0) return@forEachIndexed
            val barHeight = height * scale.fraction(value)
            drawRect(
                s.color,
                topLeft = Offset(left + slotLeft + g * each, height - barHeight),
                size = Size(maxOf(1f, each - if (groups > 1) 1f else 0f), barHeight),
            )
        }
    }
}

private fun DrawScope.drawLines(series: List<ChartSeries>, scale: ChartScale, left: Float, width: Float, height: Float) {
    for (s in series) {
        val count = s.values.size
        if (count == 0) continue
        val path = Path()
        s.values.forEachIndexed { index, value ->
            val (slotLeft, slotWidth) = barSlot(index, count, width)
            val x = left + slotLeft + slotWidth / 2
            val y = height * (1 - scale.fraction(value))
            if (index == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        drawPath(path, s.color, style = Stroke(width = 2.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
    }
}

private fun DrawScope.drawLabel(
    measurer: TextMeasurer,
    text: String,
    style: TextStyle,
    anchor: Offset,
    alignEnd: Boolean = false,
    centreX: Boolean = false,
    top: Boolean = false,
) {
    val layout = measurer.measure(text, style)
    val x = when {
        alignEnd -> anchor.x - layout.size.width
        centreX -> anchor.x - layout.size.width / 2f
        else -> anchor.x
    }.coerceIn(0f, maxOf(0f, size.width - layout.size.width))
    val y = if (top) anchor.y else anchor.y - layout.size.height / 2f
    drawText(layout, topLeft = Offset(x, y.coerceIn(0f, maxOf(0f, size.height - layout.size.height))))
}

/** A row of figures: a Lilex value over a muted caption. */
@Composable
fun StatRow(stats: List<Pair<String, String>>, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Metrics.xl)) {
        stats.forEach { (label, value) ->
            Column {
                Text(value, style = PriorityTheme.type.mono.copy(fontSize = PriorityTheme.type.heading.fontSize), color = PriorityTheme.colors.ink, maxLines = 1)
                Text(label, style = PriorityTheme.type.small, color = PriorityTheme.colors.mutedText, maxLines = 1)
            }
        }
    }
}
