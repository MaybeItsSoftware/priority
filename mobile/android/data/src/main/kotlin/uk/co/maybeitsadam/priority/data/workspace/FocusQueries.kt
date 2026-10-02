package uk.co.maybeitsadam.priority.data.workspace

import java.time.Instant
import java.time.ZoneId
import uk.co.maybeitsadam.priority.core.DailyContribution
import uk.co.maybeitsadam.priority.core.DailyItem
import uk.co.maybeitsadam.priority.core.DayPlanSelector
import uk.co.maybeitsadam.priority.core.FocusAward
import uk.co.maybeitsadam.priority.core.FocusContext
import uk.co.maybeitsadam.priority.core.FocusPointsSummary
import uk.co.maybeitsadam.priority.core.FocusQueueState
import uk.co.maybeitsadam.priority.core.FocusQueueTask
import uk.co.maybeitsadam.priority.core.FocusSession
import uk.co.maybeitsadam.priority.core.FocusSessionPhase
import uk.co.maybeitsadam.priority.core.FocusWorkBlock
import uk.co.maybeitsadam.priority.core.NextUpCandidate
import uk.co.maybeitsadam.priority.core.NextUpSelector
import uk.co.maybeitsadam.priority.core.PeriodicSchedule
import uk.co.maybeitsadam.priority.core.TaskAvailabilityPolicy
import uk.co.maybeitsadam.priority.core.TaskCondition
import uk.co.maybeitsadam.priority.core.TaskList
import uk.co.maybeitsadam.priority.core.TaskPlanning
import uk.co.maybeitsadam.priority.core.TaskStatus
import uk.co.maybeitsadam.priority.core.TaskUnavailableReason
import uk.co.maybeitsadam.priority.core.WorkBlockTime
import uk.co.maybeitsadam.priority.core.WorkProgress
import uk.co.maybeitsadam.priority.core.WorkProgressSummary
import uk.co.maybeitsadam.priority.core.WorkspaceDaily
import uk.co.maybeitsadam.priority.core.WorkspaceListTree
import uk.co.maybeitsadam.priority.core.WorkspaceNextUpSnapshot
import uk.co.maybeitsadam.priority.core.WorkspaceTask
import uk.co.maybeitsadam.priority.core.earned
import uk.co.maybeitsadam.priority.data.db.Db

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
        if (!daily.isDue(day, zone)) return@mapNotNull null
        val task = db.task(daily.taskId)?.takeIf { !it.isList } ?: return@mapNotNull null
        val contribution = db.queryOne(
            "SELECT * FROM daily_contributions WHERE dailyId = ? AND dayKey = ?", daily.id, key,
        ) { it.toContribution() }
        DailyItem(daily, task, contribution)
    }
}

internal fun dueDaily(db: Db, taskId: String, day: Instant, zone: ZoneId): WorkspaceDaily? =
    db.queryOne("SELECT * FROM dailies WHERE taskId = ? AND archivedAt IS NULL", taskId) { it.toDaily() }
        ?.takeIf { it.isDue(day, zone) }

internal fun recordContribution(
    db: Db,
    daily: WorkspaceDaily,
    seconds: Int,
    complete: Boolean,
    now: Instant,
    zone: ZoneId,
): DailyContribution {
    val key = DailyContribution.dayKey(now, zone)
    db.queryOne(
        "SELECT * FROM daily_contributions WHERE dailyId = ? AND dayKey = ?", daily.id, key,
    ) { it.toContribution() }?.let { existing ->
        val updated = existing.copy(
            secondsLogged = existing.secondsLogged + maxOf(0, seconds),
            completedAt = if (complete) existing.completedAt ?: now else existing.completedAt,
        )
        db.update(updated)
        return updated
    }
    val contribution = DailyContribution(
        id = newId(), dailyId = daily.id, taskId = daily.taskId, dayKey = key, secondsLogged = maxOf(0, seconds),
        completedAt = if (complete) now else null, createdAt = now,
    )
    db.insert(contribution)
    return contribution
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
            if (!daily.isDue(now, zone)) {
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

/**
 * Writes the next occurrence of a repeating task after one is closed. Nil when
 * the rule is missing or unreadable, which must not stop the completion.
 */
internal fun scheduleNextOccurrence(db: Db, task: WorkspaceTask, now: Instant, zone: ZoneId): WorkspaceTask? {
    if (task.isList) return null
    val metadata = db.metadata(task.id) ?: return null
    val schedule = metadata.recurrenceRule?.let { PeriodicSchedule.parse(it) } ?: return null
    fun rolled(date: Instant?) = date?.let { schedule.nextOccurrence(it, now, zone) }
    val dueAt = rolled(task.dueAt)
    val startAt = rolled(metadata.startAt) ?: if (dueAt == null) schedule.nextOccurrence(now, now, zone) else null
    if (startAt == null && dueAt == null) return null

    val next = WorkspaceTask(
        id = newId(), listId = task.listId, parentTaskId = task.parentTaskId, title = task.title, notes = task.notes,
        status = TaskStatus.OPEN, sortOrder = task.sortOrder, dueAt = dueAt, estimateSeconds = task.estimateSeconds,
        sourceSystem = null, sourceId = null, itemKind = task.itemKind, isPromoted = task.isPromoted,
        archivedAt = null, completedAt = null, createdAt = now, updatedAt = now,
    )
    db.insert(next)
    // What describes the work carries over; what describes this sitting does not.
    db.insert(
        metadata.copy(
            taskId = next.id, startAt = startAt, kanbanColumn = null, focusRank = null, updatedAt = now,
        ),
    )
    val siblings = db.taskSiblings(task.listId, task.parentTaskId).filter { it.id != next.id }.toMutableList()
    val index = siblings.indexOfFirst { it.id == task.id }
    if (index >= 0) {
        siblings.add(index + 1, next)
        db.persistTaskOrder(siblings, now)
    }
    return db.task(next.id) ?: next
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
internal fun completeActiveFocusTask(
    db: Db,
    sessionId: String,
    elapsedSeconds: Int,
    qualityMultiplier: Double?,
    completeTask: Boolean,
    expectedBlockId: String?,
    context: FocusContext,
    now: Instant,
    zone: ZoneId,
): FocusCompletion {
    var session = db.session(sessionId) ?: fail(WorkspaceStoreError.NO_ACTIVE_FOCUS_TASK)
    if (expectedBlockId != null && db.workBlockExists(expectedBlockId)) {
        return FocusCompletion(session, FocusCompletionOutcome.ProgressLogged(0), null)
    }
    val activeId = session.activeTaskId ?: fail(WorkspaceStoreError.NO_ACTIVE_FOCUS_TASK)
    val blockId = expectedBlockId ?: session.activeBlockId ?: "legacy-${session.id}/$activeId"
    if (db.workBlockExists(blockId)) return FocusCompletion(session, FocusCompletionOutcome.ProgressLogged(0), null)
    if (expectedBlockId != null && expectedBlockId != session.activeBlockId) fail(WorkspaceStoreError.NO_ACTIVE_FOCUS_TASK)

    var outcome: FocusCompletionOutcome = if (completeTask) {
        FocusCompletionOutcome.TaskCompleted
    } else {
        FocusCompletionOutcome.ProgressLogged(maxOf(0, elapsedSeconds))
    }
    val activeTask = db.task(activeId)
    val daily = dueDaily(db, activeId, now, zone)
    if (daily != null) {
        val credited = maxOf(0, elapsedSeconds)
        val metTarget = daily.targetSeconds?.let { target ->
            val logged = db.int(
                "SELECT secondsLogged FROM daily_contributions WHERE dailyId = ? AND dayKey = ?",
                daily.id, DailyContribution.dayKey(now, zone),
            ) ?: 0
            target > 0 && logged + credited >= target
        } ?: false
        recordContribution(db, daily, credited, completeTask || metTarget, now, zone)
        outcome = FocusCompletionOutcome.ContributionLogged(credited)
    } else if (completeTask && activeTask != null) {
        val wasOpen = activeTask.completedAt == null
        val closed = activeTask.copy(
            status = TaskStatus.COMPLETED, completedAt = activeTask.completedAt ?: now, updatedAt = now,
        )
        db.update(closed)
        if (wasOpen) scheduleNextOccurrence(db, closed, now, zone)
    }
    db.insert(
        FocusWorkBlock(
            id = blockId, sessionId = session.id, taskId = activeTask?.id,
            taskTitle = activeTask?.title ?: "Deleted task", seconds = maxOf(0, elapsedSeconds), recordedAt = now,
            originalTaskId = activeTask?.id,
        ),
    )
    var award: FocusAward? = null
    if (qualityMultiplier != null && elapsedSeconds > 0) {
        award = FocusAward.earned(
            id = blockId, sessionId = sessionId, taskId = activeTask?.id,
            taskTitle = activeTask?.title ?: "Untitled task", seconds = elapsedSeconds,
            multiplier = qualityMultiplier, awardedAt = now,
        ).also { db.insert(it) }
    }
    db.queryOne(
        "SELECT * FROM focus_queue_items WHERE sessionId = ? AND taskId = ? AND state = 'queued'", sessionId, activeId,
    ) { it.toQueueItem() }?.let { item ->
        db.update(item.copy(state = FocusQueueState.COMPLETED, completedAt = now))
    }
    val candidates = focusCandidates(db, now, zone).associateBy { it.id }
    val pending = db.query(
        "SELECT * FROM focus_queue_items WHERE sessionId = ? AND state = 'queued' ORDER BY sortOrder", sessionId,
    ) { it.toQueueItem() }
    val next = pending.firstOrNull { item ->
        candidates[item.taskId]?.let { TaskAvailabilityPolicy.reasons(it, context, now).isEmpty() } ?: false
    }
    session = session.copy(
        activeTaskId = next?.taskId, activeTaskStartedAt = now, accumulatedSeconds = 0, pausedAt = null,
        checkpointAt = now, activeBlockId = if (next == null) null else newId(),
    )
    val nextCandidate = next?.let { candidates[it.taskId] }
    session = when {
        next != null && nextCandidate != null -> session.copy(
            workDurationSeconds = TaskAvailabilityPolicy.plannedSeconds(nextCandidate, next.plannedSeconds, context, now),
        )
        next != null -> session
        pending.isEmpty() -> session.copy(phase = FocusSessionPhase.FINISHED, endedAt = now)
        // Keep the blocked queue available; never fabricate a new running task.
        else -> session.copy(pausedAt = now)
    }
    db.update(session)
    return FocusCompletion(session, outcome, award)
}

internal fun workBlocksIn(db: Db, start: Instant, end: Instant): List<FocusWorkBlock> = db.query(
    "SELECT * FROM focus_work_blocks WHERE recordedAt >= ? AND recordedAt < ? ORDER BY recordedAt, id", start, end,
) { it.toWorkBlock() }

internal fun completionsIn(db: Db, start: Instant, end: Instant): List<Instant> = db.query(
    "SELECT completedAt FROM tasks WHERE completedAt IS NOT NULL AND completedAt >= ? AND completedAt < ? " +
        "AND COALESCE(itemKind, 'task') <> 'list' ORDER BY completedAt",
    start, end,
) { it.instant("completedAt") }

internal fun workProgress(db: Db, now: Instant, zone: ZoneId): WorkProgress {
    val start = WorkProgressSummary.startOfWeek(now, zone)
    val end = now.atZone(zone).toLocalDate().plusDays(1).atStartOfDay(zone).toInstant()
    if (end <= start) return WorkProgress.EMPTY
    return WorkProgressSummary.summarise(
        completions = completionsIn(db, start, end),
        blocks = workBlocksIn(db, start, end).map { WorkBlockTime(it.seconds, it.recordedAt) },
        now = now,
        zone = zone,
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
