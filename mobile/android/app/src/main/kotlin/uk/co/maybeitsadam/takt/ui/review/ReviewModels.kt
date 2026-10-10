package uk.co.maybeitsadam.takt.ui.review

import androidx.compose.runtime.Immutable
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.util.Locale
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.log10
import kotlin.math.pow
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.ImmutableMap
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toImmutableList
import kotlinx.collections.immutable.toImmutableMap
import uk.co.maybeitsadam.takt.core.CompletedWorkDayKind
import uk.co.maybeitsadam.takt.core.TaskStatus
import uk.co.maybeitsadam.takt.core.CompletedWorkDigest
import uk.co.maybeitsadam.takt.core.FocusAward
import uk.co.maybeitsadam.takt.core.FocusDayTimeline
import uk.co.maybeitsadam.takt.core.FocusWorkBlock
import uk.co.maybeitsadam.takt.core.TaskProgressPeriod
import uk.co.maybeitsadam.takt.core.ReviewProgressDays
import uk.co.maybeitsadam.takt.core.WorkspaceTask

/** The three faces of Review. */
enum class ReviewSection(val title: String) { TIMELINE("Timeline"), DONE("Done"), PROGRESS("Progress") }

/** A task finished on the timeline's day: a marker on the ruler. */
@Immutable
data class TimelineCompletion(val taskId: String, val listId: String, val title: String, val at: Instant, val cancelled: Boolean)

/**
 * One day of focus laid out on an hour ruler, with a per-task breakdown. Port
 * of iOS `TimelineDay`: blocks are grouped by the task they belong to (kept
 * across renames and deletion), and each task takes an identity hue that the
 * ruler and the breakdown share.
 */
@Immutable
data class TimelineDay(
    val day: LocalDate,
    val layout: FocusDayTimeline.Layout,
    val totalSeconds: Int,
    val points: Double,
    val summaries: ImmutableList<TaskSummary>,
    /** Block id to task key, for colouring a block by its task. */
    val taskKeys: ImmutableMap<String, String>,
    val completions: ImmutableList<TimelineCompletion>,
) {
    @Immutable
    data class TaskSummary(val id: String, val title: String, val seconds: Int, val blocks: Int, val hue: Int)

    /** A logged block as the timeline needs it. */
    data class Input(val id: String, val taskKey: String, val title: String, val seconds: Int, val recordedAt: Instant) {
        constructor(block: FocusWorkBlock) : this(
            block.id, block.originalTaskId ?: block.taskId ?: block.taskTitle, block.taskTitle, block.seconds, block.recordedAt,
        )
    }

    /** The running block, measured to [now]. */
    data class Live(val id: String, val taskId: String, val title: String, val seconds: Int)

    fun hue(blockId: String): Int {
        val key = taskKeys[blockId] ?: blockId
        return summaries.firstOrNull { it.id == key }?.hue ?: 0
    }

    /** Minutes from the ruler's start to [instant], or null when it falls outside the window. */
    fun offsetMinutes(instant: Instant): Double? {
        if (instant < layout.start || instant > layout.end) return null
        return (instant.toEpochMilli() - layout.start.toEpochMilli()) / 60_000.0
    }

    companion object {
        fun build(
            day: LocalDate,
            blocks: List<Input>,
            awards: List<FocusAward>,
            live: Live?,
            completions: List<WorkspaceTask> = emptyList(),
            now: Instant = Instant.now(),
            zone: ZoneId = ZoneId.systemDefault(),
        ): TimelineDay {
            val given = blocks.map { FocusDayTimeline.Block(it.id, it.title, it.seconds, it.recordedAt) }.toMutableList()
            val keys = blocks.map { it.taskKey }.toMutableList()
            if (live != null) {
                given += FocusDayTimeline.Block(live.id, live.title, live.seconds, now, isLive = true)
                keys += live.taskId
            }
            val shaped = FocusDayTimeline.reviewDay(
                given, keys, awards.map { it.id to it.points }, day.atStartOfDay(zone).toInstant(), now, zone,
            )
            return TimelineDay(
                day = day,
                layout = shaped.layout,
                totalSeconds = shaped.totalSeconds,
                points = shaped.points,
                summaries = shaped.summaries.mapIndexed { hue, it -> TaskSummary(it.id, it.title, it.seconds, it.blocks, hue) }
                    .toImmutableList(),
                taskKeys = shaped.taskKeys.toImmutableMap(),
                completions = completions.mapNotNull { task ->
                    task.completedAt?.let { TimelineCompletion(task.id, task.listId, task.title, it, task.status == TaskStatus.CANCELLED) }
                }.sortedBy { it.at }.toImmutableList(),
            )
        }
    }
}

/** A day of the progress charts: tasks finished, tasks added, minutes focused, and running totals. */
@Immutable
data class ProgressDay(
    val day: Instant,
    val completed: Int,
    val added: Int,
    val focusMinutes: Int,
    val cumulativeCompleted: Int,
    val cumulativeAdded: Int,
)

@Immutable
data class ProgressSummary(
    val period: TaskProgressPeriod = TaskProgressPeriod.WEEK,
    val days: ImmutableList<ProgressDay> = persistentListOf(),
    val totalCompleted: Int = 0,
    val totalAdded: Int = 0,
    val focusMinutes: Int = 0,
    val bestDay: ProgressDay? = null,
) {
    val net: Int get() = totalCompleted - totalAdded

    companion object {
        /** The core's reading (`ReviewProgressDays`), in the charts' types. */
        fun of(period: TaskProgressPeriod, read: ReviewProgressDays): ProgressSummary {
            val days = read.days.map {
                ProgressDay(it.dayStart, it.completed, it.added, it.focusMinutes, it.cumulativeCompleted, it.cumulativeAdded)
            }
            return ProgressSummary(
                period = period,
                days = days.toImmutableList(),
                totalCompleted = read.totalCompleted,
                totalAdded = read.totalAdded,
                focusMinutes = read.focusMinutes,
                bestDay = read.bestDay?.let { days[it] },
            )
        }

        /** From moments in hand, for tests: the core's `summarise_review_progress`. */
        fun build(
            period: TaskProgressPeriod,
            completions: List<Instant>,
            creations: List<Instant>,
            blocks: List<Pair<Int, Instant>>,
            now: Instant = Instant.now(),
            zone: ZoneId = ZoneId.systemDefault(),
        ): ProgressSummary = of(period, ReviewProgressDays.summarise(period, completions, creations, blocks, now, zone))
    }
}

/** A value axis that ends on a round number, with evenly spaced ticks. */
@Immutable
data class ChartScale(val max: Double, val ticks: ImmutableList<Double>) {
    /** 0 at the baseline, 1 at the top. */
    fun fraction(value: Double): Float = if (max <= 0) 0f else (value / max).coerceIn(0.0, 1.0).toFloat()

    companion object {
        /**
         * The smallest "nice" axis (1, 2, 2.5 or 5 times a power of ten per
         * step) at or above [maxValue], split into at most [targetTicks] steps.
         * An empty series still gets an axis from 0 to [targetTicks].
         */
        fun nice(maxValue: Double, targetTicks: Int = 4): ChartScale {
            val ticks = maxOf(1, targetTicks)
            if (maxValue <= 0) return ChartScale(ticks.toDouble(), (0..ticks).map { it.toDouble() }.toImmutableList())
            val rough = maxValue / ticks
            val magnitude = 10.0.pow(floor(log10(rough)))
            val step = listOf(1.0, 2.0, 2.5, 5.0, 10.0).map { it * magnitude }.first { it >= rough - 1e-9 }
            // Whole-number data never needs fractional steps.
            val wholeStep = if (step < 1) 1.0 else step
            val top = ceil(maxValue / wholeStep) * wholeStep
            val count = (top / wholeStep).toInt()
            return ChartScale(top, (0..count).map { it * wholeStep }.toImmutableList())
        }
    }
}

/** Where bar [index] of [count] sits across [width]: its left edge and width, with a gap between bars. */
fun barSlot(index: Int, count: Int, width: Float, gapFraction: Float = 0.25f): Pair<Float, Float> {
    if (count <= 0) return 0f to 0f
    val slot = width / count
    val gap = if (count > 1) slot * gapFraction else 0f
    val barWidth = maxOf(1f, slot - gap)
    return index * slot + (slot - barWidth) / 2 to barWidth
}

/** One day of the done rail. */
@Immutable
data class DoneGroup(val day: Instant, val kind: CompletedWorkDayKind, val items: ImmutableList<DoneItem>) {
    fun title(zone: ZoneId = ZoneId.systemDefault()): String = doneDayTitle(day, kind, zone)
}

@Immutable
data class DoneItem(val task: WorkspaceTask, val listName: String)

/** Today, Yesterday, a weekday name within the week, otherwise `Mon 3 Oct`. */
fun doneDayTitle(day: Instant, kind: CompletedWorkDayKind, zone: ZoneId = ZoneId.systemDefault()): String = when (kind) {
    CompletedWorkDayKind.TODAY -> "Today"
    CompletedWorkDayKind.YESTERDAY -> "Yesterday"
    CompletedWorkDayKind.THIS_WEEK -> day.atZone(zone).dayOfWeek.getDisplayName(TextStyle.FULL, Locale.UK)
    CompletedWorkDayKind.EARLIER -> DateTimeFormatter.ofPattern("EEE d MMM", Locale.ENGLISH).format(day.atZone(zone))
}

/** Finished work grouped by day, newest first, each with its list's name. */
fun doneGroups(
    tasks: List<WorkspaceTask>,
    listNames: Map<String, String>,
    now: Instant = Instant.now(),
    zone: ZoneId = ZoneId.systemDefault(),
): ImmutableList<DoneGroup> = CompletedWorkDigest.group(tasks, { it.completedAt ?: Instant.EPOCH }, now, zone).map { group ->
    DoneGroup(group.dayStart, group.kind, group.items.map { DoneItem(it, listNames[it.listId] ?: "") }.toImmutableList())
}.toImmutableList()

/** The day strip's days: the [count] days ending with [today], oldest first. */
fun dayStrip(today: LocalDate, count: Int = 14): List<LocalDate> = (count - 1 downTo 0).map { today.minusDays(it.toLong()) }

/** `Mon` for the strip. */
fun shortWeekday(day: DayOfWeek): String = day.getDisplayName(TextStyle.SHORT, Locale.UK)
