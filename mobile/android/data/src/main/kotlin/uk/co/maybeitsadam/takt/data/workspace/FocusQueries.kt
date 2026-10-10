package uk.co.maybeitsadam.takt.data.workspace

import java.time.Instant
import java.time.ZoneId
import uk.co.maybeitsadam.takt.core.DailyContribution
import uk.co.maybeitsadam.takt.core.DailyItem
import uk.co.maybeitsadam.takt.core.FocusAward
import uk.co.maybeitsadam.takt.core.FocusContext
import uk.co.maybeitsadam.takt.core.FocusPointsSummary
import uk.co.maybeitsadam.takt.core.FocusQueueTask
import uk.co.maybeitsadam.takt.core.FocusSession
import uk.co.maybeitsadam.takt.core.FocusSessionPhase
import uk.co.maybeitsadam.takt.core.FocusWorkBlock
import uk.co.maybeitsadam.takt.core.NextUpCandidate
import uk.co.maybeitsadam.takt.core.NextUpSelector
import uk.co.maybeitsadam.takt.core.TaskCondition
import uk.co.maybeitsadam.takt.core.TaskList
import uk.co.maybeitsadam.takt.core.TaskPlanning
import uk.co.maybeitsadam.takt.core.WorkProgress
import uk.co.maybeitsadam.takt.core.of
import uk.co.maybeitsadam.takt.core.WorkspaceNextUpSnapshot
import uk.co.maybeitsadam.takt.core.WorkspaceTask
import uk.co.maybeitsadam.takt.core.coreMillis
import uk.co.maybeitsadam.takt.core.coreName
import uk.co.maybeitsadam.takt.core.earned
import uk.co.maybeitsadam.takt.core.defaultFirstWeekday
import uk.co.maybeitsadam.takt.data.db.Db
import uniffi.takt_core.CoreWorkspace

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

internal fun conditionsIn(db: Db, workspaceId: String): List<TaskCondition> =
    db.core.conditions(workspaceId).map { it.toCondition() }

internal fun taskPlanningValues(db: Db): Map<String, TaskPlanning> =
    db.core.allMetadata().map { it.toMetadata() }
        .mapNotNull { record -> planning(record)?.let { record.taskId to it } }
        .toMap()

internal fun hasManualFocusOrder(db: Db): Boolean = db.core.hasManualFocusOrder()

internal fun loggedWorkTotals(db: Db): Map<String, Int> =
    db.core.loggedWork().associate { it.taskId to it.seconds.toInt() }

/** The Rust core's `rows::dailies_on`, which the Mac and iPhone call too. */
internal fun dailiesOn(db: Db, day: Instant, zone: ZoneId): List<DailyItem> =
    db.core.dailiesOn(day.coreMillis, zone.coreName).map { it.toItem() }

/**
 * Every open task that could be done now, shaped for `NextUpSelector`: the
 * Rust core's `focus::candidates`, the same query the Mac and iPhone make.
 */
internal fun focusCandidates(core: CoreWorkspace, now: Instant, zone: ZoneId): List<NextUpCandidate> =
    core.nextUpCandidates(now.coreMillis, zone.coreName).map(::NextUpCandidate)

internal fun activeSession(db: Db): FocusSession? = db.core.activeFocusSession()?.toSession()

internal fun focusQueue(db: Db, sessionId: String): List<FocusQueueTask> =
    db.core.focusQueue(sessionId).map { it.toQueueTask() }

internal fun finishSession(db: Db, id: String, now: Instant) {
    val session = db.session(id) ?: return
    db.update(session.copy(phase = FocusSessionPhase.FINISHED, endedAt = now, breakEndsAt = null))
}

@Suppress("LongParameterList")

internal fun workBlocksIn(db: Db, start: Instant, end: Instant): List<FocusWorkBlock> =
    db.core.workBlocksBetween(start.coreMillis, end.coreMillis).map { it.toWorkBlock() }

internal fun completionsIn(db: Db, start: Instant, end: Instant): List<Instant> =
    db.core.taskCompletionsBetween(start.coreMillis, end.coreMillis).map(Instant::ofEpochMilli)

internal fun workProgress(
    db: Db,
    now: Instant,
    zone: ZoneId,
    firstWeekday: Int = defaultFirstWeekday(),
): WorkProgress =
    // The Rust core's `progress::work_progress`: it reads the week's rows and
    // sums them itself, so none of them cross.
    WorkProgress.of(db.core.workProgress(now.coreMillis, zone.coreName, firstWeekday.toUByte()))

internal fun pointsSummary(db: Db, now: Instant, zone: ZoneId): FocusPointsSummary {
    val today = now.atZone(zone).toLocalDate()
    val start = today.atStartOfDay(zone).toInstant()
    val tomorrow = today.plusDays(1).atStartOfDay(zone).toInstant()
    val weekStart = today.minusDays(6).atStartOfDay(zone).toInstant()
    val summary = db.core.focusPointsSummary(start.coreMillis, tomorrow.coreMillis, weekStart.coreMillis)
    return FocusPointsSummary(
        today = summary.today,
        last7Days = summary.last7Days,
        allTime = summary.allTime,
        blocksToday = summary.blocksToday.toInt(),
    )
}

internal fun nextUpSnapshot(
    db: Db,
    core: CoreWorkspace,
    workspaceId: String?,
    context: FocusContext,
    runningId: String?,
    now: Instant,
    zone: ZoneId,
): WorkspaceNextUpSnapshot {
    val (plan, ranking) = NextUpSelector.read(core, now, zone, context, runningId)
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


