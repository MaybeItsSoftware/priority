package uk.co.maybeitsadam.takt.core

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit

// Port of Sources/TaktWorkspace/WorkspaceModels.swift (and the record types in
// TaskPlanning.swift). `Date` becomes `Instant`; a Swift `Calendar` becomes the
// `ZoneId` it would resolve days in. Weekdays keep Calendar numbering: 1 = Sunday.

data class Workspace(
    val id: String,
    val name: String,
    val createdAt: Instant,
    val updatedAt: Instant,
)

data class ListFolder(
    val id: String,
    val workspaceId: String,
    val parentFolderId: String?,
    val name: String,
    val sortOrder: Int,
    val createdAt: Instant,
    val updatedAt: Instant,
)

/** A job the workspace relies on a list to do. The name is the user's; the role is the workspace's. */
enum class TaskListRole(val raw: String) {
    INBOX("inbox");

    companion object {
        fun of(raw: String?): TaskListRole? = entries.firstOrNull { it.raw == raw }
    }
}

data class TaskList(
    val id: String,
    val workspaceId: String,
    val folderId: String?,
    val name: String,
    val colorHex: String?,
    val sortOrder: Int,
    val isArchived: Boolean,
    val systemRole: TaskListRole?,
    /** An imported wrapper whose children form the list's visible root. */
    val visibleRootTaskId: String?,
    val completedAt: Instant?,
    val createdAt: Instant,
    val updatedAt: Instant,
) {
    val isSystemList: Boolean get() = systemRole != null
}

enum class TaskStatus(val raw: String) {
    OPEN("open"),
    COMPLETED("completed"),
    CANCELLED("cancelled");

    companion object {
        fun of(raw: String): TaskStatus = entries.firstOrNull { it.raw == raw } ?: OPEN
    }
}

enum class WorkspaceItemKind(val raw: String) {
    TASK("task"),
    LIST("list");

    companion object {
        fun of(raw: String?): WorkspaceItemKind? = entries.firstOrNull { it.raw == raw }
    }
}

data class WorkspaceTask(
    val id: String,
    val listId: String,
    val parentTaskId: String?,
    val title: String,
    val notes: String,
    val status: TaskStatus,
    val sortOrder: Int,
    val dueAt: Instant?,
    val estimateSeconds: Int?,
    /** Where an imported task came from; nil for a task typed into Priority. */
    val sourceSystem: String?,
    val sourceId: String?,
    val itemKind: WorkspaceItemKind?,
    val isPromoted: Boolean?,
    val archivedAt: Instant?,
    /** When the task was closed; nil whenever `status` is open. */
    val completedAt: Instant? = null,
    val createdAt: Instant,
    val updatedAt: Instant,
) {
    val isList: Boolean get() = itemKind == WorkspaceItemKind.LIST
}

data class TaskOutlineItem(val task: WorkspaceTask, val depth: Int) {
    val id: String get() = task.id
}

data class TaskMetadata(
    val taskId: String,
    val priority: Int?,
    val startAt: Instant?,
    val tagsJSON: String,
    val recurrenceRule: String?,
    val matrixUrgency: Int?,
    val matrixImportance: Int?,
    val kanbanColumn: String?,
    val externalLinksJSON: String,
    /** Hand-placed position in the focus ladder; nil means ranked by score. */
    val focusRank: Int? = null,
    val updatedAt: Instant,
    val planningJSON: String? = null,
    /** Who or what the task waits on, while it is in `waiting-on`. See [WaitingFollowUp]. */
    val waitingOn: String? = null,
    /** When to chase it. */
    val waitingFollowUpAt: Instant? = null,
    /** The follow-up already made for this task, so it is made once per time. */
    val waitingFollowUpTaskId: String? = null,
    /** On a follow-up task: the waiting task it chases. */
    val followUpOfTaskId: String? = null,
)

data class TaskEditorMetadata(
    val priority: Int? = null,
    val tags: List<String> = emptyList(),
    val recurrenceRule: String? = null,
    val externalLinks: List<String> = emptyList(),
)

/** A board column. The task's column is independent of its parent's column. */
data class WorkspaceKanbanColumn(val id: String, val title: String) {
    companion object {
        val blitzitDefaults = listOf(
            WorkspaceKanbanColumn("backlog", "Backlog"),
            WorkspaceKanbanColumn("in-progress", "In progress"),
            WorkspaceKanbanColumn("this-week", "This week"),
            WorkspaceKanbanColumn("waiting-on", "Waiting on"),
            WorkspaceKanbanColumn("today", "Today"),
        )
    }
}

data class TaskMatrixPosition(val urgency: Int?, val importance: Int?)

enum class FocusSessionPhase(val raw: String) {
    RUNNING("running"),
    ON_BREAK("onBreak"),
    FINISHED("finished");

    companion object {
        fun of(raw: String): FocusSessionPhase = entries.firstOrNull { it.raw == raw } ?: FINISHED
    }
}

data class FocusSession(
    val id: String,
    val startedAt: Instant,
    val endedAt: Instant?,
    val phase: FocusSessionPhase,
    val activeTaskId: String?,
    /** When the current task's block began, as distinct from the session's own start. */
    val activeTaskStartedAt: Instant,
    val workDurationSeconds: Int,
    val breakDurationSeconds: Int,
    val breakEndsAt: Instant?,
    val activeBlockId: String?,
    val accumulatedSeconds: Int?,
    val pausedAt: Instant?,
    val checkpointAt: Instant?,
) {
    fun elapsedSeconds(now: Instant): Int {
        val running = if (pausedAt == null) {
            maxOf(0.0, secondsBetween(activeTaskStartedAt, now)).toInt()
        } else {
            0
        }
        return maxOf(0, accumulatedSeconds ?: 0) + running
    }
}

enum class FocusQueueState(val raw: String) {
    QUEUED("queued"),
    COMPLETED("completed"),
    SKIPPED("skipped");

    companion object {
        fun of(raw: String): FocusQueueState = entries.firstOrNull { it.raw == raw } ?: QUEUED
    }
}

data class FocusQueueItem(
    val id: String,
    val sessionId: String,
    val taskId: String,
    val sortOrder: Int,
    val state: FocusQueueState,
    /** What you committed to when you started this sitting. */
    val plannedSeconds: Int?,
    val completedAt: Instant?,
    val skippedAt: Instant?,
    val createdAt: Instant,
)

data class FocusQueueTask(val item: FocusQueueItem, val task: WorkspaceTask) {
    val id: String get() = item.id
}

/**
 * A standing commitment to move one task forward today. Fixed weekdays, or a
 * rotating interval, never both; `intervalDays` wins when set.
 */
data class WorkspaceDaily(
    val id: String,
    val taskId: String,
    /** Calendar weekday numbering (1 = Sunday) as a bitmask, bit `n - 1` per weekday. */
    val activeWeekdaysMask: Int = ALL_WEEKDAYS_MASK,
    val intervalDays: Int? = null,
    val intervalAnchor: Instant? = null,
    val targetSeconds: Int? = null,
    val sortOrder: Int,
    val archivedAt: Instant? = null,
    val legacyDailyId: String? = null,
    val createdAt: Instant,
    val updatedAt: Instant,
) {
    val isArchived: Boolean get() = archivedAt != null

    val activeWeekdays: Set<Int> get() = (1..7).filter { activeWeekdaysMask and (1 shl (it - 1)) != 0 }.toSet()

    /** Whether this daily is expected on `day`. */
    fun isDue(day: Instant, zone: ZoneId = ZoneId.systemDefault()): Boolean {
        if (isArchived) return false
        val interval = intervalDays
        if (interval != null && interval > 0) {
            val anchor = (intervalAnchor ?: createdAt).atZone(zone).toLocalDate()
            val target = day.atZone(zone).toLocalDate()
            if (target < anchor) return false
            val elapsed = ChronoUnit.DAYS.between(anchor, target)
            return elapsed % interval == 0L
        }
        return activeWeekdaysMask and (1 shl (calendarWeekday(day.atZone(zone).toLocalDate()) - 1)) != 0
    }

    companion object {
        const val ALL_WEEKDAYS_MASK = 0b111_1111

        /** The normalising initialiser: a zero mask means every day, the interval is clamped to 1...366. */
        fun make(
            id: String,
            taskId: String,
            activeWeekdaysMask: Int = ALL_WEEKDAYS_MASK,
            intervalDays: Int? = null,
            intervalAnchor: Instant? = null,
            targetSeconds: Int? = null,
            sortOrder: Int,
            archivedAt: Instant? = null,
            legacyDailyId: String? = null,
            createdAt: Instant,
            updatedAt: Instant,
        ) = WorkspaceDaily(
            id = id,
            taskId = taskId,
            activeWeekdaysMask = if (activeWeekdaysMask == 0) ALL_WEEKDAYS_MASK else activeWeekdaysMask,
            intervalDays = intervalDays?.coerceIn(1, 366),
            intervalAnchor = intervalAnchor,
            targetSeconds = targetSeconds,
            sortOrder = sortOrder,
            archivedAt = archivedAt,
            legacyDailyId = legacyDailyId,
            createdAt = createdAt,
            updatedAt = updatedAt,
        )

        fun mask(weekdays: Set<Int>): Int = weekdays.fold(0) { acc, d -> acc or (1 shl (d - 1)) }
    }
}

/** One day's progress against a daily's task, keyed by `yyyy-MM-dd` in the user's zone. */
data class DailyContribution(
    val id: String,
    val dailyId: String,
    val taskId: String,
    val dayKey: String,
    val secondsLogged: Int,
    val completedAt: Instant?,
    val createdAt: Instant,
) {
    val isComplete: Boolean get() = completedAt != null

    companion object {
        private val dayKeyFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd")

        fun dayKey(date: Instant, zone: ZoneId = ZoneId.systemDefault()): String =
            date.atZone(zone).toLocalDate().format(dayKeyFormatter)
    }
}

data class DailyItem(
    val daily: WorkspaceDaily,
    val task: WorkspaceTask,
    val contribution: DailyContribution?,
) {
    val id: String get() = daily.id
    val isDoneToday: Boolean get() = contribution?.isComplete ?: false
    val secondsLoggedToday: Int get() = contribution?.secondsLogged ?: 0
}

data class TaskCondition(
    val id: String,
    val workspaceId: String,
    val name: String,
    val isLocation: Boolean,
    val isArchived: Boolean,
    val createdAt: Instant,
    val updatedAt: Instant,
)

data class FocusWorkBlock(
    val id: String,
    val sessionId: String?,
    val taskId: String?,
    val taskTitle: String,
    val seconds: Int,
    val recordedAt: Instant,
    val originalTaskId: String?,
)

data class FocusAward(
    val id: String,
    val sessionId: String?,
    val taskId: String?,
    val taskTitle: String,
    val seconds: Int,
    val minutes: Double,
    val multiplier: Double,
    val points: Double,
    val awardedAt: Instant,
) {
    /** Extended in FocusPoints.kt with `earned(...)`, Swift's deriving initialiser. */
    companion object
}

/** `Calendar.component(.weekday)`: 1 = Sunday ... 7 = Saturday. */
fun calendarWeekday(date: LocalDate): Int = date.dayOfWeek.value % 7 + 1

/** `Date.timeIntervalSince` as fractional seconds. */
fun secondsBetween(from: Instant, to: Instant): Double =
    (to.epochSecond - from.epochSecond) + (to.nano - from.nano) / 1_000_000_000.0

/** `Calendar.current.firstWeekday` for the default locale: 1 = Sunday, 2 = Monday. */
fun defaultFirstWeekday(locale: java.util.Locale = java.util.Locale.getDefault()): Int =
    calendarWeekday(LocalDate.of(2024, 1, 1).with(java.time.temporal.WeekFields.of(locale).dayOfWeek(), 1))
