package uk.co.maybeitsadam.takt.ui.focus

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import uk.co.maybeitsadam.takt.core.FocusPoints
import uk.co.maybeitsadam.takt.core.FocusQuality
import uk.co.maybeitsadam.takt.ui.components.Format
import uk.co.maybeitsadam.takt.ui.components.Hairline
import uk.co.maybeitsadam.takt.ui.components.MonoText
import uk.co.maybeitsadam.takt.ui.components.PButton
import uk.co.maybeitsadam.takt.ui.theme.TaktTheme
import uk.co.maybeitsadam.takt.ui.theme.Metrics

/**
 * How did that block go? The presets (×0.5 to ×2) or a custom multiplier up
 * to ×5 scale its minutes into points. "Skip scoring" credits the time with
 * no score; "Keep working" drops the question and resumes the clock.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun QualityPrompt(
    pending: PendingCompletion,
    onScore: (Double?) -> Unit,
    onCancel: () -> Unit,
) {
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var multiplier by rememberSaveable(pending) { mutableDoubleStateOf(FocusQuality.SOLID.multiplier) }
    ModalBottomSheet(
        onDismissRequest = onCancel,
        sheetState = sheet,
        containerColor = TaktTheme.colors.paper,
        contentColor = TaktTheme.colors.ink,
        tonalElevation = 0.dp,
        shape = Metrics.card,
        modifier = Modifier.testTag("quality_prompt"),
    ) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).navigationBarsPadding().padding(horizontal = Metrics.lg),
            verticalArrangement = Arrangement.spacedBy(Metrics.md),
        ) {
            Text("How did that go?", style = TaktTheme.type.title, color = TaktTheme.colors.ink)
            Column(verticalArrangement = Arrangement.spacedBy(Metrics.xxs)) {
                Text(pending.title, style = TaktTheme.type.heading, color = TaktTheme.colors.ink, maxLines = 2)
                MonoText(
                    "${Format.duration(pending.seconds)} · ${if (pending.completeTask) "finishes the task" else "task stays open"}",
                )
            }
            Column(
                Modifier.clip(Metrics.card).background(TaktTheme.colors.raised).border(BorderStroke(Metrics.hairline, TaktTheme.colors.border), Metrics.card),
            ) {
                FocusQuality.entries.forEachIndexed { index, quality ->
                    if (index > 0) Hairline(color = TaktTheme.colors.borderMuted)
                    val isOn = multiplier == quality.multiplier
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .heightIn(min = Metrics.touchTarget)
                            .clickable(role = Role.RadioButton) { multiplier = quality.multiplier }
                            .semantics { selected = isOn }
                            .testTag("quality_${quality.raw}")
                            .padding(horizontal = Metrics.md, vertical = Metrics.sm),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(Metrics.sm),
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text(quality.title, style = TaktTheme.type.body, color = TaktTheme.colors.ink)
                            Text(quality.detail, style = TaktTheme.type.small, color = TaktTheme.colors.mutedText)
                        }
                        MonoText(FocusText.multiplier(quality.multiplier), color = if (isOn) TaktTheme.colors.primary else TaktTheme.colors.mutedText)
                        Box(
                            Modifier.size(18.dp).clip(CircleShape)
                                .border(BorderStroke(if (isOn) 5.dp else 1.5.dp, if (isOn) TaktTheme.colors.primary else TaktTheme.colors.inputBorder), CircleShape),
                        )
                    }
                }
            }
            Column {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Custom multiplier", style = TaktTheme.type.label, color = TaktTheme.colors.mutedText, modifier = Modifier.weight(1f))
                    MonoText(FocusText.multiplier(multiplier), color = TaktTheme.colors.ink)
                }
                Slider(
                    value = multiplier.toFloat(),
                    onValueChange = { multiplier = Math.round(it * 4) / 4.0 },
                    valueRange = MIN_MULTIPLIER..FocusPoints.multiplierRange.endInclusive.toFloat(),
                    steps = ((FocusPoints.multiplierRange.endInclusive - MIN_MULTIPLIER) / 0.25).toInt() - 1,
                    colors = SliderDefaults.colors(
                        thumbColor = TaktTheme.colors.primary,
                        activeTrackColor = TaktTheme.colors.primary,
                        inactiveTrackColor = TaktTheme.colors.well,
                        activeTickColor = TaktTheme.colors.primary,
                        inactiveTickColor = TaktTheme.colors.inputBorder,
                    ),
                    modifier = Modifier.testTag("quality_custom"),
                )
                MonoText(
                    "Earns ${FocusText.points(pending.seconds, multiplier)}",
                    style = TaktTheme.type.mono,
                    color = TaktTheme.colors.ink,
                    modifier = Modifier.testTag("quality_points"),
                )
            }
            PButton("Log it", Modifier.fillMaxWidth().testTag("quality_log"), primary = true) { onScore(multiplier) }
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.sm)) {
                PButton("Skip scoring", Modifier.weight(1f)) { onScore(null) }
                PButton("Keep working", Modifier.weight(1f)) { onCancel() }
            }
            Box(Modifier.heightIn(min = Metrics.lg))
        }
    }
}

private const val MIN_MULTIPLIER = 0.5f
