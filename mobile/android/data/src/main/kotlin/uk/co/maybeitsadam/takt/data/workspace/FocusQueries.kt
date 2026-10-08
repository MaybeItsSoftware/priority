package uk.co.maybeitsadam.takt.data.workspace

import java.time.Instant
import java.time.ZoneId
import uk.co.maybeitsadam.takt.core.DailyContribution
import uk.co.maybeitsadam.takt.core.DailyItem
import uk.co.maybeitsadam.takt.core.DayPlanSelector
import uk.co.maybeitsadam.takt.core.FocusAward
import uk.co.maybeitsadam.takt.core.FocusContext
import uk.co.maybeitsadam.takt.core.FocusPointsSummary
import uk.co.maybeitsadam.takt.core.FocusQueueState
import uk.co.maybeitsadam.takt.core.FocusQueueTask
import uk.co.maybeitsadam.takt.core.FocusSession
import uk.co.maybeitsadam.takt.core.FocusSessionPhase
import uk.co.maybeitsadam.takt.core.FocusWorkBlock
import uk.co.maybeitsadam.takt.core.NextUpCandidate
import uk.co.maybeitsadam.takt.core.NextUpSelector
import uk.co.maybeitsadam.takt.core.PeriodicSchedule
import uk.co.maybeitsadam.takt.core.TaskAvailabilityPolicy
import uk.co.maybeitsadam.takt.core.TaskCondition
import uk.co.maybeitsadam.takt.core.TaskList
import uk.co.maybeitsadam.takt.core.TaskPlanning
import uk.co.maybeitsadam.takt.core.TaskStatus
import uk.co.maybeitsadam.takt.core.TaskUnavailableReason
import uk.co.maybeitsadam.takt.core.WorkBlockTime
import uk.co.maybeitsadam.takt.core.WorkProgress
import uk.co.maybeitsadam.takt.core.WorkProgressSummary
import uk.co.maybeitsadam.takt.core.WorkspaceDaily
import uk.co.maybeitsadam.takt.core.WorkspaceListTree
import uk.co.maybeitsadam.takt.core.WorkspaceNextUpSnapshot
import uk.co.maybeitsadam.takt.core.WorkspaceTask
import uk.co.maybeitsadam.takt.core.earned
import uk.co.maybeitsadam.takt.core.defaultFirstWeekday
import uk.co.maybeitsadam.takt.data.db.Db

/** A value an edit may leave alone ([Keep]) or set, possibly to null ([To]); Swift's `Int??`. */
sealed interface FieldEdit<out T> {
    data object Keep : FieldEdit<Nothing>
    data class To<T>(val value: T) : FieldEdit<T>
}

/** What a celebration needs to know about today. */
data class CompletionContext(
    /** How many things are finished today, this one included; 1 is the first. */
    val ordinalToday: Int,
    /** Consecutive days ending today on which something was finished. */
    val streakDays: Int,
)

/** One search hit, with the list it lives in. */
data class TaskSearchResult(val task: WorkspaceTask, val list: TaskList, val notesSnippet: String?) {
    val id: String get() = task.id
}

data class TaskCounts(val open: Int, val completed: Int, val byList: Map<String, Int>)

/** What finishing a focus block did to the underlying task. */
sealed interface FocusCompletionOutcome {
    data object TaskCompleted : FocusCompletionOutcome
    data class ProgressLogged(val seconds: Int) : FocusCompletionOutcome
    data class ContributionLogged(val seconds: Int) : FocusCompletionOutcome
}

data class FocusCompletion(
    val session: FocusSession,
    val outcome: FocusCompletionOutcome,
    /** The points the block earned; nil without a quality judgement or measurable time. */
    val award: FocusAward?,
)

internal fun conditionsIn(db: Db, workspaceId: String): List<TaskCondition> = db.query(
    "SELECT * FROM task_conditions WHERE workspaceId = ? ORDER BY createdAt, id", workspaceId,
) { it.toCondition() }

internal fun taskPlanningValues(db: Db): Map<String, TaskPlanning> =
    db.query("SELECT * FROM task_metadata") { it.toMetadata() }
        .mapNotNull { record -> planning(record)?.let { record.taskId to it } }
        .toMap()

internal fun hasManualFocusOrder(db: Db): Boolean =
    (db.int("SELECT COUNT(*) FROM task_metadata WHERE focusRank IS NOT NULL") ?: 0) > 0

internal fun loggedWorkTotals(db: Db): Map<String, Int> = db.query(
    "SELECT COALESCE(taskId, originalTaskId) AS taskId, SUM(seconds) AS seconds FROM focus_work_blocks " +
        "WHERE COALESCE(taskId, originalTaskId) IS NOT NULL GROUP BY COALESCE(taskId, originalTaskId)",
) { it.string("taskId") to it.int("seconds") }.toMap()

internal fun dailiesOn(db: Db, day: Instant, zone: ZoneId): List<DailyItem> {
    val key = DailyContribution.dayKey(day, zone)
    val dailies = db.query("SELECT * FROM dailies WHERE archivedAt IS NULL ORDER BY sortOrder, createdAt") { it.toDaily() }
    return dailies.mapNotNull { daily ->
        if (!dailyShows(db, daily, day, zone)) return@mapNotNull null
        val task = db.task(daily.taskId)?.takeIf { !it.isList } ?: return@mapNotNull null
        val contribution = db.queryOne(
            "SELECT * FROM daily_contributions WHERE dailyId = ? AND dayKey = ?", daily.id, key,
        ) { it.toContribution() }
        DailyItem(daily, task, contribution)
    }
}

/**
 * Every open task that could be done now, shaped for `NextUpSelector`. Parents
 * with open children, lists, wrappers and tasks in closed containers are left
 * out; dailies already met today drop away unless something is due.
 */
internal fun focusCandidates(db: Db, now: Instant, zone: ZoneId): List<NextUpCandidate> {
    val dayKey = DailyContribution.dayKey(now, zone)
    val archived = db.strings("SELECT id FROM task_lists WHERE isArchived OR completedAt IS NOT NULL").toSet()
    val allTasks = db.query("SELECT * FROM tasks") { it.toTask() }
    val inactive = WorkspaceListTree.inactiveContainerItems(allTasks)
    val wrappers = db.strings("SELECT visibleRootTaskId FROM task_lists WHERE visibleRootTaskId IS NOT NULL").toSet()
    val parents = db.strings(
        "SELECT DISTINCT parentTaskId FROM tasks WHERE parentTaskId IS NOT NULL AND status = 'open'",
    ).toSet()
    val metadata = db.query("SELECT * FROM task_metadata") { it.toMetadata() }.associateBy { it.taskId }
    val dailies = LinkedHashMap<String, WorkspaceDaily>()
    db.query("SELECT * FROM dailies WHERE archivedAt IS NULL") { it.toDaily() }.forEach { dailies.putIfAbsent(it.taskId, it) }
    val contributions = db.query("SELECT * FROM daily_contributions WHERE dayKey = ?", dayKey) { it.toContribution() }
        .associateBy { it.dailyId }
    val work = loggedWorkTotals(db)
    return allTasks.filter { it.status == TaskStatus.OPEN }.mapNotNull { task ->
        if (task.isList || task.id in inactive || task.id in wrappers || task.listId in archived || task.id in parents) {
            return@mapNotNull null
        }
        val record = metadata[task.id]
        val plan = planning(record)
        val daily = dailies[task.id]
        val contribution = daily?.let { contributions[it.id] }
        var dailyUnavailable: TaskUnavailableReason? = null
        if (daily != null) {
            if (!dailyShows(db, daily, now, zone)) {
                dailyUnavailable = TaskUnavailableReason.DailyNotScheduled
            } else if (contribution?.completedAt != null ||
                (daily.targetSeconds?.let { it > 0 && (contribution?.secondsLogged ?: 0) >= it } ?: false)
            ) {
                dailyUnavailable = TaskUnavailableReason.DailyAlreadyMet
            }
            if (dailyUnavailable != null && task.dueAt == null && plan?.dueDate == null) return@mapNotNull null
        }
        NextUpCandidate(
            id = task.id, title = task.title, isDailyDueToday = daily != null && dailyUnavailable == null,
            dueAt = task.dueAt, startAt = record?.startAt, matrixUrgency = record?.matrixUrgency,
            matrixImportance = record?.matrixImportance, priority = record?.priority,
            estimateSeconds = task.estimateSeconds, kanbanColumn = record?.kanbanColumn, focusRank = record?.focusRank,
            sortOrder = task.sortOrder, createdAt = task.createdAt, dueDate = plan?.dueDate,
            requirementGroups = plan?.requirementGroups ?: emptyList(), loggedSeconds = work[task.id] ?: 0,
            minimumBlockSeconds = plan?.minimumBlockSeconds, requiresSingleSitting = plan?.requiresSingleSitting == true,
            dailyRemainingSeconds = daily?.targetSeconds?.let { maxOf(0, it - (contribution?.secondsLogged ?: 0)) },
            dailyUnavailable = dailyUnavailable,
        )
    }
}

internal fun activeSession(db: Db, newestFirst: Boolean = true): FocusSession? = db.queryOne(
    "SELECT * FROM focus_sessions WHERE phase != 'finished'" + if (newestFirst) " ORDER BY startedAt DESC" else "",
) { it.toSession() }

internal fun focusQueue(db: Db, sessionId: String): List<FocusQueueTask> =
    db.query("SELECT * FROM focus_queue_items WHERE sessionId = ? ORDER BY sortOrder, createdAt", sessionId) {
        it.toQueueItem()
    }.mapNotNull { item -> db.task(item.taskId)?.takeIf { !it.isList }?.let { FocusQueueTask(item, it) } }

internal fun finishSession(db: Db, id: String, now: Instant) {
    val session = db.session(id) ?: return
    db.update(session.copy(phase = FocusSessionPhase.FINISHED, endedAt = now, breakEndsAt = null))
}

@Suppress("LongParameterList")

internal fun workBlocksIn(db: Db, start: Instant, end: Instant): List<FocusWorkBlock> = db.query(
    "SELECT * FROM focus_work_blocks WHERE recordedAt >= ? AND recordedAt < ? ORDER BY recordedAt, id", start, end,
) { it.toWorkBlock() }

internal fun completionsIn(db: Db, start: Instant, end: Instant): List<Instant> = db.query(
    "SELECT completedAt FROM tasks WHERE completedAt IS NOT NULL AND completedAt >= ? AND completedAt < ? " +
        "AND COALESCE(itemKind, 'task') <> 'list' ORDER BY completedAt",
    start, end,
) { it.instant("completedAt") }

internal fun workProgress(
    db: Db,
    now: Instant,
    zone: ZoneId,
    firstWeekday: Int = defaultFirstWeekday(),
): WorkProgress {
    val start = WorkProgressSummary.startOfWeek(now, zone, firstWeekday)
    val end = now.atZone(zone).toLocalDate().plusDays(1).atStartOfDay(zone).toInstant()
    if (end <= start) return WorkProgress.EMPTY
    return WorkProgressSummary.summarise(
        completions = completionsIn(db, start, end),
        blocks = workBlocksIn(db, start, end).map { WorkBlockTime(it.seconds, it.recordedAt) },
        now = now,
        zone = zone,
        firstWeekday = firstWeekday,
    )
}

internal fun pointsSummary(db: Db, now: Instant, zone: ZoneId): FocusPointsSummary {
    val today = now.atZone(zone).toLocalDate()
    val start = today.atStartOfDay(zone).toInstant()
    val tomorrow = today.plusDays(1).atStartOfDay(zone).toInstant()
    val weekStart = today.minusDays(6).atStartOfDay(zone).toInstant()
    fun total(from: Instant?, upTo: Instant?): Double {
        val conditions = listOfNotNull(from?.let { "awardedAt >= ?" }, upTo?.let { "awardedAt < ?" })
        val where = if (conditions.isEmpty()) "" else " WHERE " + conditions.joinToString(" AND ")
        return db.queryOne("SELECT SUM(points) FROM focus_awards$where", *listOfNotNull(from, upTo).toTypedArray()) {
            if (it.isNull(0)) 0.0 else it.double(0)
        } ?: 0.0
    }
    return FocusPointsSummary(
        today = total(start, tomorrow),
        last7Days = total(weekStart, tomorrow),
        allTime = total(null, null),
        blocksToday = db.int("SELECT COUNT(*) FROM focus_awards WHERE awardedAt >= ? AND awardedAt < ?", start, tomorrow)
            ?: 0,
    )
}

internal fun nextUpSnapshot(
    db: Db,
    workspaceId: String?,
    context: FocusContext,
    runningId: String?,
    now: Instant,
    zone: ZoneId,
): WorkspaceNextUpSnapshot {
    val candidates = focusCandidates(db, now, zone)
    val plan = DayPlanSelector.plan(candidates = candidates, runningID = runningId, now = now, zone = zone)
    val ranking = NextUpSelector.evaluate(candidates, now, zone, context)
    return WorkspaceNextUpSnapshot(
        loggedSeconds = loggedWorkTotals(db),
        planning = taskPlanningValues(db),
        conditions = workspaceId?.let { conditionsIn(db, it) } ?: emptyList(),
        todayPlan = plan,
        workProgress = workProgress(db, now, zone),
        ranking = ranking,
        dayTasks = tasksById(db, WorkspaceNextUpSnapshot.dayTaskIDs(plan, ranking)),
        hasManualFocusOrder = hasManualFocusOrder(db),
    )
}

/**
 * GRDB's `FTS5Pattern(matchingAllPrefixesIn:)`: the query split into tokens the
 * way FTS5's ascii tokenizer would, each quoted and made a prefix. Nil when
 * nothing is left to match on.
 */
internal fun ftsPrefixPattern(query: String): String? {
    val tokens = mutableListOf<String>()
    val current = StringBuilder()
    for (c in query) {
        val separator = c.code < 128 && !c.isLetterOrDigit()
        if (separator) {
            if (current.isNotEmpty()) tokens += current.toString()
            current.clear()
        } else {
            current.append(if (c.code < 128) c.lowercaseChar() else c)
        }
    }
    if (current.isNotEmpty()) tokens += current.toString()
    if (tokens.isEmpty()) return null
    return tokens.joinToString(" ") { "\"$it\"*" }
}
