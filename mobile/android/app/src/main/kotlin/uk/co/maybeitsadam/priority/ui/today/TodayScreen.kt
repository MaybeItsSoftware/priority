package uk.co.maybeitsadam.priority.ui.today

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import java.time.LocalDate
import uk.co.maybeitsadam.priority.core.DayPlanReason
import uk.co.maybeitsadam.priority.core.FocusSession
import uk.co.maybeitsadam.priority.core.TaskStatus
import uk.co.maybeitsadam.priority.ui.commands.KeyCommand
import uk.co.maybeitsadam.priority.ui.commands.RegisterCommands
import uk.co.maybeitsadam.priority.ui.components.EmptyState
import uk.co.maybeitsadam.priority.ui.components.Format
import uk.co.maybeitsadam.priority.ui.components.Hairline
import uk.co.maybeitsadam.priority.ui.components.IconAction
import uk.co.maybeitsadam.priority.ui.components.MonoText
import uk.co.maybeitsadam.priority.ui.components.PButton
import uk.co.maybeitsadam.priority.ui.components.PriorityTopBar
import uk.co.maybeitsadam.priority.ui.components.SectionHeader
import uk.co.maybeitsadam.priority.ui.components.SettingsAction
import uk.co.maybeitsadam.priority.ui.components.TaskCheck
import uk.co.maybeitsadam.priority.ui.focus.BlockIconButton
import uk.co.maybeitsadam.priority.ui.focus.ClockReading
import uk.co.maybeitsadam.priority.ui.focus.QualityPrompt
import uk.co.maybeitsadam.priority.ui.focus.isTicking
import uk.co.maybeitsadam.priority.ui.focus.rememberNotificationGate
import uk.co.maybeitsadam.priority.ui.focus.rememberTicker
import uk.co.maybeitsadam.priority.ui.navigation.LocalShell
import uk.co.maybeitsadam.priority.ui.navigation.Tab
import uk.co.maybeitsadam.priority.ui.quickadd.QuickAddBar
import uk.co.maybeitsadam.priority.ui.theme.PriorityTheme
import uk.co.maybeitsadam.priority.ui.theme.Metrics
import uk.co.maybeitsadam.priority.ui.theme.PIcons
import uk.co.maybeitsadam.priority.ui.theme.parseHexColor

/**
 * The day: the running block first, then what was planned (in hand order,
 * draggable), overdue, due today and starting today; with nothing planned,
 * the top of the ranking. A forecast says what the day still owes and when
 * it would be done. The Mac's `DayView`, for a phone.
 */
@Composable
fun TodayScreen() {
    val shell = LocalShell.current
    val container = shell.container
    val vm = viewModel { TodayViewModel(container) }
    val day by vm.state.collectAsStateWithLifecycle()
    val pending by vm.pendingCompletion.collectAsStateWithLifecycle()
    val gate = rememberNotificationGate()
    val listState = rememberLazyListState()
    val drag = rememberPlannedDrag(listState)

    RegisterCommands(
        listOf(
            KeyCommand.GO_FOCUS.palette { shell.navigator.openTab(Tab.FOCUS) },
        ),
    )

    Column(Modifier.fillMaxSize().background(PriorityTheme.colors.paper)) {
        PriorityTopBar("Today", subtitle = longDay(LocalDate.now()), actions = { SettingsAction() })
        QuickAddBar(listId = null)
        val sections = day.sections
        val plannedIds = day.plannedIds
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize().testTag("today_list"),
            contentPadding = PaddingValues(bottom = 96.dp),
        ) {
            item(key = "forecast", contentType = "forecast") { DayHeader(day) }
            for (section in sections) {
                item(key = "section-${section.kind.name}", contentType = "section") {
                    SectionHeader(section.kind.title, detail = section.cards.size.toString())
                }
                val cards = if (section.kind == DaySectionKind.PLANNED && drag.order != null) {
                    val byId = section.cards.associateBy { it.id }
                    drag.order.orEmpty().mapNotNull(byId::get)
                } else {
                    section.cards
                }
                items(cards, key = { it.id }, contentType = { if (it.isRunning) "running" else "card" }) { card ->
                    val isDragging = drag.draggingId == card.id
                    val itemModifier = if (isDragging) {
                        Modifier.zIndex(1f).graphicsLayer { translationY = drag.offset }
                    } else {
                        Modifier.animateItem()
                    }
                    if (card.isRunning && day.session != null) {
                        RunningDayCard(
                            card = card,
                            session = day.session!!,
                            onPause = vm::togglePause,
                            onLog = { vm.requestCompletion(completeTask = false) },
                            onDone = { vm.requestCompletion(completeTask = true) },
                            onOpen = { vm.inspect(card) },
                            modifier = itemModifier,
                        )
                    } else {
                        DayCardRow(
                            card = card,
                            isDragging = isDragging,
                            canStart = true,
                            onTick = { vm.tickOff(card) },
                            onStart = { gate { vm.start(card) } },
                            onOpen = { vm.inspect(card) },
                            menu = { dismiss ->
                                CardMenu(card, vm, dismiss, onStart = { gate { vm.start(card) } })
                            },
                            handle = if (card.isPlanned && plannedIds.size > 1) {
                                Modifier.plannedDragHandle(drag, card.id, plannedIds, vm::arrange)
                            } else {
                                null
                            },
                            modifier = itemModifier,
                        )
                    }
                }
            }
            if (day.dailies.isNotEmpty()) {
                item(key = "section-dailies", contentType = "section") {
                    SectionHeader("Dailies", detail = "${day.dailies.count { it.isDone }}/${day.dailies.size}")
                }
                items(day.dailies, key = { "daily-${it.id}" }, contentType = { "daily" }) { daily ->
                    DailyRow(daily, onToggle = { vm.toggleDaily(daily) }, modifier = Modifier.animateItem())
                }
            }
            if (day.isLoaded && day.cards.isEmpty() && day.dailies.isEmpty()) {
                item(key = "empty", contentType = "empty") {
                    EmptyState(
                        "Nothing planned for today",
                        detail = "Plan a task for today from its menu, or add one above.",
                    )
                }
            }
        }
    }

    pending?.let { completion ->
        QualityPrompt(completion, onScore = vm::confirmCompletion, onCancel = vm::cancelCompletion)
    }
}

private fun longDay(date: LocalDate): String =
    date.format(java.time.format.DateTimeFormatter.ofPattern("EEEE d MMMM", java.util.Locale.UK))

// region Header

/** What the day costs against what it has cost, and when it ends if worked straight through. */
@Composable
private fun DayHeader(day: DayState) {
    val ticking = day.session?.isTicking == true
    val now by rememberTicker(active = true, periodMillis = if (ticking) 30_000 else 60_000)
    val forecast = remember(day.cards, day.session, now) { DayShaping.forecast(day.cards, day.session, now) }
    Column(Modifier.fillMaxWidth().padding(horizontal = Metrics.lg, vertical = Metrics.md), verticalArrangement = Arrangement.spacedBy(Metrics.sm)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            val finish = forecast.finishAt
            Text(
                if (finish != null) "done by ${Format.time(finish)}" else if (forecast.estimatedSeconds > 0) "All estimates spent" else "No finish time",
                style = PriorityTheme.type.mono.copy(fontSize = PriorityTheme.type.heading.fontSize),
                color = if (finish != null) PriorityTheme.colors.primary else PriorityTheme.colors.mutedText,
                modifier = Modifier.weight(1f).testTag("today_forecast"),
            )
            MonoText(forecast.spentText, color = PriorityTheme.colors.ink, modifier = Modifier.testTag("today_tally"))
        }
        val fraction = if (forecast.estimatedSeconds > 0) minOf(1f, forecast.loggedSeconds.toFloat() / forecast.estimatedSeconds) else 0f
        Box(Modifier.fillMaxWidth().height(4.dp).background(PriorityTheme.colors.well)) {
            Box(Modifier.fillMaxWidth(fraction).height(4.dp).background(PriorityTheme.colors.primary))
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            MonoText(
                "est ${DayForecast.hoursAndMinutes(forecast.estimatedSeconds)} · logged ${DayForecast.hoursAndMinutes(forecast.loggedSeconds)}",
                style = PriorityTheme.type.monoSmall,
                modifier = Modifier.weight(1f),
            )
            Text(forecast.remainingText, style = PriorityTheme.type.small, color = PriorityTheme.colors.mutedText, maxLines = 1)
        }
        val progress = day.workProgress
        if (progress.week.seconds > 0 || progress.week.completed > 0) {
            Row {
                Text(
                    if (progress.today.completed == 1) "1 done today" else "${progress.today.completed} done today",
                    style = PriorityTheme.type.small, color = PriorityTheme.colors.mutedText, modifier = Modifier.weight(1f),
                )
                MonoText(
                    "${Format.duration(progress.today.seconds)} today · ${Format.duration(progress.week.seconds)} this week",
                    style = PriorityTheme.type.monoSmall,
                )
            }
        }
    }
    Hairline()
}

// endregion

// region Cards

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun DayCardRow(
    card: DayCard,
    isDragging: Boolean,
    canStart: Boolean,
    onTick: () -> Unit,
    onStart: () -> Unit,
    onOpen: () -> Unit,
    menu: @Composable (dismiss: () -> Unit) -> Unit,
    handle: Modifier?,
    modifier: Modifier = Modifier,
) {
    var menuOpen by remember { mutableStateOf(false) }
    Column(modifier.background(if (isDragging) PriorityTheme.colors.raised else PriorityTheme.colors.paper)) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(start = Metrics.xs, end = Metrics.xs),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TaskCheck(
                status = if (card.isDailyDoneToday) TaskStatus.COMPLETED else TaskStatus.OPEN,
                isList = card.isList,
                label = card.title,
                onToggle = onTick,
            )
            Box(Modifier.weight(1f)) {
                Column(
                    Modifier
                        .fillMaxWidth()
                        .clip(Metrics.control)
                        .combinedClickable(onClick = onOpen, onLongClick = { menuOpen = true }, onLongClickLabel = "Task actions")
                        .padding(vertical = Metrics.sm, horizontal = Metrics.xs),
                ) {
                    Text(card.title, style = PriorityTheme.type.body, color = PriorityTheme.colors.ink, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    CardDetail(card)
                }
                ChalkMenu(menuOpen, onDismiss = { menuOpen = false }) { menu { menuOpen = false } }
            }
            CardCost(card)
            if (canStart) {
                IconAction(Icons.Filled.PlayArrow, "Start focus on ${card.title}", tint = PriorityTheme.colors.primary, onClick = onStart)
            }
            if (handle != null) {
                Box(
                    handle.size(Metrics.touchTarget).semantics { contentDescription = "Reorder ${card.title}" },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(PIcons.DragHandle, null, tint = PriorityTheme.colors.dimText, modifier = Modifier.size(20.dp))
                }
            }
        }
        Hairline(color = PriorityTheme.colors.borderMuted)
    }
}

@Composable
private fun CardDetail(card: DayCard) {
    val detail = DayShaping.detail(card) { Format.due(it) }
    val tint = when (card.reason) {
        DayPlanReason.OVERDUE -> PriorityTheme.colors.danger
        DayPlanReason.DUE_TODAY -> PriorityTheme.colors.primary
        DayPlanReason.STARTS_TODAY -> PriorityTheme.colors.success
        else -> PriorityTheme.colors.mutedText
    }
    if (detail == null && card.listName == null && card.dailyId == null) return
    Row(horizontalArrangement = Arrangement.spacedBy(Metrics.xs + Metrics.xxs), verticalAlignment = Alignment.CenterVertically) {
        if (detail != null) Text(detail, style = PriorityTheme.type.small, color = tint, maxLines = 1)
        if (card.dailyId != null) {
            Icon(PIcons.Repeat, "Daily", tint = PriorityTheme.colors.categoricalPurple, modifier = Modifier.size(12.dp))
        }
        card.listName?.let { name ->
            val dot = parseHexColor(card.listColorHex)
            if (dot != null) Box(Modifier.size(6.dp).clip(Metrics.control).background(dot))
            Text(name, style = PriorityTheme.type.small, color = PriorityTheme.colors.mutedText, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun CardCost(card: DayCard) {
    val estimate = card.estimateSeconds
    val text = when {
        estimate != null && estimate > 0 && card.loggedSeconds > 0 -> "${Format.duration(card.loggedSeconds)}/${Format.duration(estimate)}"
        estimate != null && estimate > 0 -> Format.duration(estimate)
        card.loggedSeconds > 0 -> Format.duration(card.loggedSeconds)
        else -> return
    }
    val over = estimate != null && card.loggedSeconds > estimate
    MonoText(text, color = if (over) PriorityTheme.colors.warning else PriorityTheme.colors.mutedText, modifier = Modifier.padding(start = Metrics.xs))
}

@Composable
private fun CardMenu(card: DayCard, vm: TodayViewModel, dismiss: () -> Unit, onStart: () -> Unit) {
    ChalkMenuItem(if (card.isPlanned) "Take off today" else "Plan for today") { dismiss(); vm.togglePlanned(card) }
    if (card.isPlanned) {
        ChalkMenuItem("Move up in the day") { dismiss(); vm.movePlanned(card.id, -1) }
        ChalkMenuItem("Move down in the day") { dismiss(); vm.movePlanned(card.id, 1) }
    }
    ChalkMenuItem("Due today") { dismiss(); vm.dueToday(card) }
    ChalkMenuItem("Due tomorrow") { dismiss(); vm.dueTomorrow(card) }
    ChalkMenuItem("Not today") { dismiss(); vm.deferToTomorrow(card) }
    ChalkMenuItem("Start focus") { dismiss(); onStart() }
    ChalkMenuItem("Open inspector") { dismiss(); vm.inspect(card) }
}

/** The card you are on, grown: a live Lilex clock and the controls that only apply to it. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun RunningDayCard(
    card: DayCard,
    session: FocusSession,
    onPause: () -> Unit,
    onLog: () -> Unit,
    onDone: () -> Unit,
    onOpen: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val paused = session.pausedAt != null
    val now by rememberTicker(active = session.isTicking)
    val reading = ClockReading.of(session, now)
    Column(
        modifier
            .fillMaxWidth()
            .background(PriorityTheme.colors.primary.copy(alpha = 0.06f))
            .padding(horizontal = Metrics.lg, vertical = Metrics.md),
        verticalArrangement = Arrangement.spacedBy(Metrics.sm),
    ) {
        Text(
            card.title,
            style = PriorityTheme.type.title,
            color = PriorityTheme.colors.ink,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.clip(Metrics.control).combinedClickable(onClick = onOpen),
        )
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(Metrics.sm)) {
            Text(
                reading.text,
                style = PriorityTheme.type.monoLarge,
                color = when {
                    paused -> PriorityTheme.colors.mutedText
                    reading.isOverrun -> PriorityTheme.colors.warning
                    else -> PriorityTheme.colors.primary
                },
                modifier = Modifier.testTag("today_clock"),
            )
            Text(
                if (paused) "paused" else "of ${Format.duration(session.workDurationSeconds)}",
                style = PriorityTheme.type.small,
                color = if (paused) PriorityTheme.colors.warning else PriorityTheme.colors.mutedText,
                modifier = Modifier.padding(bottom = Metrics.xs + Metrics.xxs),
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.sm), verticalAlignment = Alignment.CenterVertically) {
            BlockIconButton(if (paused) Icons.Filled.PlayArrow else PIcons.Pause, if (paused) "Resume" else "Pause", onPause)
            BlockIconButton(PIcons.Timer, "Log and keep", onLog)
            Spacer(Modifier.weight(1f))
            PButton(
                "Done",
                Modifier.widthIn(min = 96.dp).semantics { contentDescription = "Finish" },
                primary = true,
                icon = Icons.Filled.Check,
                onClick = onDone,
            )
        }
    }
    Hairline(color = PriorityTheme.colors.borderMuted)
}

// endregion

// region Dailies

@Composable
private fun DailyRow(daily: DayDaily, onToggle: () -> Unit, modifier: Modifier = Modifier) {
    Column(modifier) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = Metrics.touchTarget).padding(start = Metrics.xs, end = Metrics.lg),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TaskCheck(
                status = if (daily.isDone) TaskStatus.COMPLETED else TaskStatus.OPEN,
                label = daily.title,
                onToggle = onToggle,
            )
            Column(Modifier.weight(1f).padding(horizontal = Metrics.xs)) {
                Text(
                    daily.title,
                    style = PriorityTheme.type.body,
                    color = if (daily.isDone) PriorityTheme.colors.mutedText else PriorityTheme.colors.ink,
                    textDecoration = if (daily.isDone) TextDecoration.LineThrough else null,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                daily.progressFraction?.let { fraction ->
                    Box(Modifier.padding(top = Metrics.xs).width(120.dp).height(3.dp).background(PriorityTheme.colors.well)) {
                        Box(Modifier.fillMaxWidth(fraction).height(3.dp).background(if (daily.isDone) PriorityTheme.colors.success else PriorityTheme.colors.categoricalPurple))
                    }
                }
            }
            daily.progressText?.let { MonoText(it) }
        }
        Hairline(color = PriorityTheme.colors.borderMuted)
    }
}

// endregion
