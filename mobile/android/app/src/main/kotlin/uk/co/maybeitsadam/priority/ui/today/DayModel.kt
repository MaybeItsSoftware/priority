package uk.co.maybeitsadam.priority.ui.today

import androidx.compose.runtime.Immutable
import java.time.Instant
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toImmutableList
import uk.co.maybeitsadam.priority.core.DailyItem
import uk.co.maybeitsadam.priority.core.DayPlanReason
import uk.co.maybeitsadam.priority.core.FocusSession
import uk.co.maybeitsadam.priority.core.FocusSessionPhase
import uk.co.maybeitsadam.priority.core.TaskList
import uk.co.maybeitsadam.priority.core.WorkProgress
import uk.co.maybeitsadam.priority.core.WorkspaceNextUpSnapshot

/** One card in the day. A value, so the list redraws only the cards that changed. */
@Immutable
data class DayCard(
    val id: String,
    val title: String,
    val listName: String?,
    val listColorHex: String?,
    /** Why the task is in the day; null for the fallback ranking, where nothing chose it. */
    val reason: DayPlanReason?,
    val estimateSeconds: Int?,
    /** Time logged across every block, before any running one. */
    val loggedSeconds: Int,
    val dueAt: Instant?,
    val isList: Boolean,
    /** A daily expected today: ticking logs a contribution rather than completing the task. */
    val dailyId: String?,
    val isDailyDoneToday: Boolean,
    val isRunning: Boolean,
) {
    val isPlanned: Boolean get() = reason == DayPlanReason.PLANNED
}

/** A daily expected today, for the dailies section under the day. */
@Immutable
data class DayDaily(
    val id: String,
    val taskId: String,
    val title: String,
    val isDone: Boolean,
    val secondsToday: Int,
    val targetSeconds: Int?,
) {
    /** `20m/30m`, `20m`, or null when there is nothing to say. */
    val progressText: String?
        get() {
            if (secondsToday <= 0 && targetSeconds == null) return null
            val logged = DayForecast.hoursAndMinutes(secondsToday)
            return targetSeconds?.let { "$logged/${DayForecast.hoursAndMinutes(it)}" } ?: logged
        }

    /** 0…1 of the target, or null without one. */
    val progressFraction: Float?
        get() = targetSeconds?.takeIf { it > 0 }?.let { minOf(1f, secondsToday.toFloat() / it) }
}

/** The headings the day reads under, in the order it is read. */
enum class DaySectionKind(val title: String) {
    RUNNING("Running"),
    PLANNED("Planned"),
    OVERDUE("Overdue"),
    DUE_TODAY("Due today"),
    STARTS_TODAY("Starts today"),
    RANKED("Nothing planned: the top of the ranking"),
    ;

    companion object {
        fun of(reason: DayPlanReason?): DaySectionKind = when (reason) {
            DayPlanReason.RUNNING -> RUNNING
            DayPlanReason.PLANNED -> PLANNED
            DayPlanReason.OVERDUE -> OVERDUE
            DayPlanReason.DUE_TODAY -> DUE_TODAY
            DayPlanReason.STARTS_TODAY -> STARTS_TODAY
            null -> RANKED
        }
    }
}

@Immutable
data class DaySection(val kind: DaySectionKind, val cards: ImmutableList<DayCard>)

/** Everything Today draws. */
@Immutable
data class DayState(
    val cards: ImmutableList<DayCard> = persistentListOf(),
    val dailies: ImmutableList<DayDaily> = persistentListOf(),
    val session: FocusSession? = null,
    val workProgress: WorkProgress = WorkProgress.EMPTY,
    /** Whether the day came from the plan rather than the fallback ranking. */
    val isPlanned: Boolean = false,
    val isLoaded: Boolean = false,
) {
    val sections: ImmutableList<DaySection> get() = DayShaping.sections(cards)
    val plannedIds: List<String> get() = cards.filter { it.isPlanned }.map { it.id }
    val runningCard: DayCard? get() = cards.firstOrNull { it.isRunning }

    /** The open day items: cards not yet done (a daily already met today is done). */
    val openCount: Int get() = cards.count { !it.isDailyDoneToday }
}

/**
 * The day's finish-by figure: what the day's estimates still owe, and now
 * plus that. Deliberately naive (no breaks, no calendar). Port of
 * `Sources/PriorityCore/DayForecast.swift`.
 */
@Immutable
data class DayForecast(
    val estimatedSeconds: Int,
    val loggedSeconds: Int,
    /** What estimated tasks still owe; an overrun on one task buys no time back on another. */
    val remainingSeconds: Int,
    val unestimatedCount: Int,
    /** `now` plus what is left, or null when nothing estimated is left. */
    val finishAt: Instant?,
) {
    data class Entry(val estimateSeconds: Int?, val loggedSeconds: Int)

    /** `1h 20m of 3h`, or `1h 20m logged` without estimates. */
    val spentText: String
        get() {
            val logged = hoursAndMinutes(loggedSeconds)
            return if (estimatedSeconds > 0) "$logged of ${hoursAndMinutes(estimatedSeconds)}" else "$logged logged"
        }

    /** `1h 40m left · 2 unestimated`, or why there is no finish time. */
    val remainingText: String
        get() {
            if (estimatedSeconds <= 0) return "No estimates yet"
            var text = if (finishAt == null) "Every estimate used up" else "${hoursAndMinutes(remainingSeconds)} left"
            if (unestimatedCount > 0) text += " · $unestimatedCount unestimated"
            return text
        }

    companion object {
        fun of(entries: List<Entry>, now: Instant): DayForecast {
            var estimated = 0
            var logged = 0
            var remaining = 0
            var unestimated = 0
            for (entry in entries) {
                val spent = maxOf(0, entry.loggedSeconds)
                logged += spent
                val estimate = entry.estimateSeconds
                if (estimate == null || estimate <= 0) {
                    unestimated++
                    continue
                }
                estimated += estimate
                remaining += maxOf(0, estimate - spent)
            }
            return DayForecast(
                estimatedSeconds = estimated,
                loggedSeconds = logged,
                remainingSeconds = remaining,
                unestimatedCount = unestimated,
                finishAt = if (remaining > 0) now.plusSeconds(remaining.toLong()) else null,
            )
        }

        /** Hours and minutes, never seconds: nobody types an estimate to the second. */
        fun hoursAndMinutes(seconds: Int): String {
            val minutes = maxOf(0, seconds) / 60
            if (minutes < 60) return "${minutes}m"
            val rest = minutes % 60
            return if (rest == 0) "${minutes / 60}h" else "${minutes / 60}h ${rest}m"
        }
    }
}

/** Pure shaping of the day, kept out of the ViewModel so it can be tested on the JVM. */
object DayShaping {
    /**
     * Reads the day the way the Mac's `rebuildDayItems` does: the plan
     * resolved to tasks, or the head of the ranking when nothing was planned.
     */
    fun build(
        snapshot: WorkspaceNextUpSnapshot,
        session: FocusSession?,
        dailies: List<DailyItem>,
        lists: List<TaskList>,
    ): DayState {
        val dailyByTask = HashMap<String, DailyItem>()
        for (item in dailies) dailyByTask.putIfAbsent(item.task.id, item)
        val listsById = lists.associateBy { it.id }
        val isPlanned = snapshot.todayPlan.isNotEmpty()
        val entries: List<Pair<String, DayPlanReason?>> = if (isPlanned) {
            snapshot.todayPlan.map { it.id to it.reason }
        } else {
            snapshot.ranking.ranked.take(WorkspaceNextUpSnapshot.fallbackDayLength).map { it.candidate.id to null }
        }
        val runningId = session?.takeIf { it.phase == FocusSessionPhase.RUNNING }?.activeTaskId
        val seen = HashSet<String>()
        val cards = entries.mapNotNull { (id, reason) ->
            if (!seen.add(id)) return@mapNotNull null
            val task = snapshot.dayTasks[id] ?: return@mapNotNull null
            val daily = dailyByTask[id]
            val list = listsById[task.listId]
            DayCard(
                id = id,
                title = task.title,
                listName = list?.name,
                listColorHex = list?.colorHex,
                reason = reason,
                estimateSeconds = task.estimateSeconds,
                loggedSeconds = snapshot.loggedSeconds[id] ?: 0,
                dueAt = task.dueAt,
                isList = task.isList,
                dailyId = daily?.daily?.id,
                isDailyDoneToday = daily?.isDoneToday ?: false,
                isRunning = id == runningId,
            )
        }
        return DayState(
            cards = cards.toImmutableList(),
            dailies = dailies.map {
                DayDaily(
                    id = it.daily.id,
                    taskId = it.task.id,
                    title = it.task.title,
                    isDone = it.isDoneToday,
                    secondsToday = it.secondsLoggedToday,
                    targetSeconds = it.daily.targetSeconds,
                )
            }.toImmutableList(),
            session = session,
            workProgress = snapshot.workProgress,
            isPlanned = isPlanned,
            isLoaded = true,
        )
    }

    /**
     * Cards grouped under their reason, in the plan's order of reasons; the
     * running card heads the day whatever brought it in.
     */
    fun sections(cards: List<DayCard>): ImmutableList<DaySection> {
        val grouped = LinkedHashMap<DaySectionKind, MutableList<DayCard>>()
        for (card in cards) {
            val kind = if (card.isRunning) DaySectionKind.RUNNING else DaySectionKind.of(card.reason?.takeUnless { it == DayPlanReason.RUNNING })
            grouped.getOrPut(kind) { mutableListOf() } += card
        }
        return DaySectionKind.entries.mapNotNull { kind ->
            grouped[kind]?.let { DaySection(kind, it.toImmutableList()) }
        }.toImmutableList()
    }

    /**
     * The forecast over the day's open cards. Stored totals gain a block only
     * when it ends, so the running card's live elapsed is added on top.
     */
    fun forecast(cards: List<DayCard>, session: FocusSession?, now: Instant): DayForecast {
        val runningId = session?.takeIf { it.phase == FocusSessionPhase.RUNNING }?.activeTaskId
        val entries = cards.filterNot { it.isDailyDoneToday }.map { card ->
            var logged = card.loggedSeconds
            if (card.id == runningId) logged += session.elapsedSeconds(now)
            DayForecast.Entry(card.estimateSeconds, logged)
        }
        return DayForecast.of(entries, now)
    }

    /** What a card says under its title: the reason beats the deadline; "planned" goes unsaid. */
    fun detail(card: DayCard, dueText: (Instant) -> String): String? = when (card.reason) {
        DayPlanReason.OVERDUE, DayPlanReason.DUE_TODAY, DayPlanReason.STARTS_TODAY -> card.reason.label
        else -> card.dueAt?.let { "Due ${dueText(it).lowercase()}" }
    }
}

/**
 * Arranging the day by hand. Only planned cards move: a derived card is in
 * the day because of a date, and the next read would put it back. Port of
 * `Sources/PriorityCore/DayArrangement.swift`.
 */
object DayArrangement {
    /** The planned order with [taskId] moved [offset] places, clamped; null when nothing moves. */
    fun moving(taskId: String, offset: Int, order: List<String>): List<String>? {
        val index = order.indexOf(taskId)
        if (offset == 0 || index < 0) return null
        val target = (index + offset).coerceIn(0, order.size - 1)
        if (target == index) return null
        return order.toMutableList().apply {
            removeAt(index)
            add(target, taskId)
        }
    }

    /** [order] replacing the planned cards, in place, so a move shows before the next read lands. */
    fun applying(order: List<String>, cards: List<DayCard>): List<DayCard> {
        val planned = cards.filter { it.isPlanned }.associateBy { it.id }
        val queue = order.iterator()
        return cards.map { card ->
            if (!card.isPlanned || !queue.hasNext()) card else planned[queue.next()] ?: card
        }
    }
}
