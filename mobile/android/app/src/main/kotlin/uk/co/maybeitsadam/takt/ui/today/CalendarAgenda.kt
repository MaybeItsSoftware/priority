package uk.co.maybeitsadam.takt.ui.today

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import uk.co.maybeitsadam.takt.settings.GoogleCalendarController
import uk.co.maybeitsadam.takt.ui.components.Hairline
import uk.co.maybeitsadam.takt.ui.components.MonoText
import uk.co.maybeitsadam.takt.ui.components.SectionHeader
import uk.co.maybeitsadam.takt.ui.theme.Metrics
import uk.co.maybeitsadam.takt.ui.theme.TaktTheme
import uk.co.maybeitsadam.takt.ui.theme.parseHexColor
import uniffi.takt_core.GoogleCalendarAgendaEntry
import uniffi.takt_core.GoogleCalendarAgendaKind

/**
 * Today's schedule (docs/google-calendar.md): the day's events from the
 * calendars chosen in settings, interleaved with timed tasks by the Rust core,
 * all-day first. An event carries its calendar's colour in a bar and opens in
 * Google Calendar; a task opens its inspector. Nothing at all when Google
 * Calendar isn't connected or the day has nothing timed.
 */
@Composable
fun CalendarAgenda(calendar: GoogleCalendarController, onOpenTask: (String) -> Unit) {
    val entries by calendar.agenda.collectAsStateWithLifecycle()
    if (entries.isEmpty()) return
    val calendars by calendar.calendars.collectAsStateWithLifecycle()
    val colours = remember(calendars) { calendars.associate { it.id to parseHexColor(it.color) } }
    val uri = LocalUriHandler.current
    Column(Modifier.fillMaxWidth().testTag("today_calendar")) {
        SectionHeader("Schedule", detail = entries.size.toString())
        entries.forEachIndexed { index, entry ->
            if (index > 0) Hairline(Modifier.padding(start = Metrics.lg), color = TaktTheme.colors.borderMuted)
            val isTask = entry.kind == GoogleCalendarAgendaKind.TASK
            val link = entry.htmlLink
            AgendaRow(
                entry,
                bar = if (isTask) null else colours[entry.calendarId] ?: TaktTheme.colors.primary,
                onClick = when {
                    isTask -> ({ onOpenTask(entry.id) })
                    link != null -> ({ runCatching { uri.openUri(link) } })
                    else -> null
                },
            )
        }
        Hairline()
    }
}

@Composable
private fun AgendaRow(entry: GoogleCalendarAgendaEntry, bar: Color?, onClick: (() -> Unit)?) {
    val colors = TaktTheme.colors
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = Metrics.touchTarget)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = Metrics.lg, vertical = Metrics.xs),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Metrics.sm),
    ) {
        MonoText(timeRange(entry), modifier = Modifier.width(TIME_WIDTH), style = TaktTheme.type.monoSmall)
        Box(Modifier.width(BAR_WIDTH).height(BAR_HEIGHT).background(bar ?: Color.Transparent, Metrics.control))
        Text(
            entry.title.ifBlank { "(No title)" },
            style = TaktTheme.type.body,
            color = if (entry.isDone) colors.mutedText else colors.ink,
            textDecoration = if (entry.isDone) TextDecoration.LineThrough else null,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
    }
}

private val clock: DateTimeFormatter = DateTimeFormatter.ofPattern("HH:mm")

private fun timeRange(entry: GoogleCalendarAgendaEntry, zone: ZoneId = ZoneId.systemDefault()): String {
    val start = entry.startMs ?: return "All day"
    val from = clock.format(Instant.ofEpochMilli(start).atZone(zone))
    val end = entry.endMs ?: return from
    return "$from–${clock.format(Instant.ofEpochMilli(end).atZone(zone))}"
}

// Layout constants: the time column fits "00:00–00:00" in the mono face.
private val TIME_WIDTH = 92.dp
private val BAR_WIDTH = 3.dp
private val BAR_HEIGHT = 20.dp
