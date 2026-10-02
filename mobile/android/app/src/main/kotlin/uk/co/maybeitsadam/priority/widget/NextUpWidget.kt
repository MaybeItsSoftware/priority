package uk.co.maybeitsadam.priority.widget

import android.content.Context
import android.content.Intent
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.color.ColorProvider
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.text.FontFamily
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import uk.co.maybeitsadam.priority.MainActivity
import uk.co.maybeitsadam.priority.appContainer
import uk.co.maybeitsadam.priority.core.FocusContext
import uk.co.maybeitsadam.priority.ui.ShellIntents
import uk.co.maybeitsadam.priority.ui.theme.ChalkPalette

/**
 * Next up, and how much of today is open. Chalk colours (paper inside a
 * hairline, ink and muted text), flipping with the system's day and night.
 * The whole widget opens Today; the task row opens its inspector.
 */
class NextUpWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val summary = runCatching {
            val session = context.appContainer.awaitSession()
            val running = session.repository.activeFocusSession()?.activeTaskId
            NextUpSummary.of(session.repository.nextUpSnapshot(session.workspace.id, FocusContext(), running), running)
        }.getOrDefault(NextUpSummary.EMPTY)
        provideContent { NextUpContent(context, summary) }
    }
}

class NextUpWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = NextUpWidget()
}

private object WidgetColors {
    private val light = ChalkPalette.ChalkLight
    private val dark = ChalkPalette.ChalkDark
    val border: ColorProvider = ColorProvider(day = light.border, night = dark.border)
    val raised: ColorProvider = ColorProvider(day = light.raised, night = dark.raised)
    val well: ColorProvider = ColorProvider(day = light.well, night = dark.well)
    val ink: ColorProvider = ColorProvider(day = light.ink, night = dark.ink)
    val muted: ColorProvider = ColorProvider(day = light.mutedText, night = dark.mutedText)
    val primary: ColorProvider = ColorProvider(day = light.primary, night = dark.primary)
}

private fun openApp(context: Context, taskId: String? = null): Intent =
    Intent(context, MainActivity::class.java)
        .setAction(if (taskId == null) "uk.co.maybeitsadam.priority.widget.TODAY" else "uk.co.maybeitsadam.priority.widget.TASK.$taskId")
        .putExtra(ShellIntents.EXTRA_TAB, "TODAY")
        .apply { if (taskId != null) putExtra(ShellIntents.EXTRA_TASK_ID, taskId) }
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)

@Composable
private fun NextUpContent(context: Context, summary: NextUpSummary) {
    // A 1dp border painted as the outer box, the paper-white card inside it.
    Box(
        GlanceModifier
            .fillMaxSize()
            .background(WidgetColors.border)
            .cornerRadius(8.dp)
            .padding(1.dp)
            .clickable(actionStartActivity(openApp(context))),
    ) {
        Column(
            GlanceModifier.fillMaxSize().background(WidgetColors.raised).cornerRadius(8.dp).padding(12.dp),
        ) {
            Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    if (summary.isRunning) "Focusing" else "Next up",
                    style = TextStyle(color = if (summary.isRunning) WidgetColors.primary else WidgetColors.muted, fontSize = 12.sp, fontWeight = FontWeight.Medium),
                    modifier = GlanceModifier.defaultWeight(),
                )
                Box(
                    GlanceModifier.background(WidgetColors.well).cornerRadius(6.dp).padding(horizontal = 6.dp, vertical = 2.dp),
                ) {
                    Text(
                        "${summary.todayCount} today",
                        style = TextStyle(color = WidgetColors.ink, fontSize = 12.sp, fontFamily = FontFamily.Monospace),
                    )
                }
            }
            Spacer(GlanceModifier.height(8.dp))
            val taskId = summary.taskId
            if (taskId == null || summary.title == null) {
                Text("Nothing to do", style = TextStyle(color = WidgetColors.ink, fontSize = 16.sp, fontWeight = FontWeight.Medium))
                Text("Add a task, or plan one for today.", style = TextStyle(color = WidgetColors.muted, fontSize = 12.sp))
            } else {
                Column(GlanceModifier.fillMaxWidth().clickable(actionStartActivity(openApp(context, taskId)))) {
                    Text(
                        summary.title,
                        maxLines = 2,
                        style = TextStyle(color = WidgetColors.ink, fontSize = 16.sp, fontWeight = FontWeight.Medium),
                    )
                    summary.reason?.let {
                        Text(it, maxLines = 1, style = TextStyle(color = WidgetColors.muted, fontSize = 12.sp))
                    }
                }
            }
        }
    }
}
