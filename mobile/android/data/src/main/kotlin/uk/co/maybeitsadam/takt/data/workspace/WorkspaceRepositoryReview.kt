package uk.co.maybeitsadam.takt.data.workspace

import java.time.Instant
import kotlinx.coroutines.flow.Flow
import uk.co.maybeitsadam.takt.core.FocusAward
import uk.co.maybeitsadam.takt.core.FocusSession
import uk.co.maybeitsadam.takt.core.FocusWorkBlock
import uk.co.maybeitsadam.takt.core.WorkspaceTask
import uk.co.maybeitsadam.takt.core.coreMillis

// Live reads behind Review (timeline, done rail, progress) and the history
// sheet. Each re-queries when one of the tables it reads is written, so a
// focus block logging, a completion or a sync pull redraws the screen.

/** One day of logged focus, and the block running now if there is one. */
data class ReviewDayRecords(
    val blocks: List<FocusWorkBlock>,
    val awards: List<FocusAward>,
    val activeSession: FocusSession?,
    /** The running task's title, when [activeSession] has an active task. */
    val activeTaskTitle: String?,
    /** Tasks (not lists) closed in the window, oldest first; cancellations included. */
    val closedTasks: List<WorkspaceTask>,
)

/** The raw timestamps the progress charts bucket into days. */
data class ReviewProgressRecords(
    val completions: List<Instant>,
    val creations: List<Instant>,
    val blocks: List<FocusWorkBlock>,
)

/** Blocks, awards and closed tasks in `[start, end)`, plus the running session. */
fun WorkspaceRepository.observeReviewDay(start: Instant, end: Instant): Flow<ReviewDayRecords> =
    database.observe(setOf("focus_work_blocks", "focus_awards", "focus_sessions", "tasks")) { db ->
        val session = activeSession(db)
        ReviewDayRecords(
            blocks = workBlocksIn(db, start, end),
            awards = db.core.focusAwardsBetween(start.coreMillis, end.coreMillis).map { it.toAward() },
            activeSession = session,
            activeTaskTitle = session?.activeTaskId?.let { db.task(it)?.title },
            closedTasks = db.core.tasksClosedBetween(start.coreMillis, end.coreMillis).map { it.toTask() },
        )
    }

/** Tasks closed since [since], newest first; lists left out, cancellations kept. */
fun WorkspaceRepository.observeCompletedTasks(since: Instant, limit: Int = 300): Flow<List<WorkspaceTask>> =
    database.observe(setOf("tasks")) { db ->
        db.core.completedTasksSince(since.coreMillis, limit.toLong()).map { it.toTask() }
    }

/** Completions, creations and focus blocks in `[start, end)`, from one read. */
fun WorkspaceRepository.observeReviewProgress(start: Instant, end: Instant): Flow<ReviewProgressRecords> =
    database.observe(setOf("tasks", "focus_work_blocks")) { db ->
        ReviewProgressRecords(
            completions = completionsIn(db, start, end),
            creations = db.core.taskCreationsBetween(start.coreMillis, end.coreMillis).map(Instant::ofEpochMilli),
            blocks = workBlocksIn(db, start, end),
        )
    }

/** The journal, newest first, re-read whenever it changes: [WorkspaceRepository.history], live. */
fun WorkspaceRepository.observeHistory(limit: Int = 100): Flow<List<HistoryEntry>> =
    database.observe(setOf("change_log")) { db ->
        db.core.undoHistory(limit.coerceAtLeast(0).toUInt()).map {
            HistoryEntry(it.id, it.label, it.isUndone, it.changeCount.toInt())
        }
    }
