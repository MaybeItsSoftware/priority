package uk.co.maybeitsadam.takt.data.workspace

import kotlinx.coroutines.flow.Flow
import uk.co.maybeitsadam.takt.core.NextUpSelector
import uk.co.maybeitsadam.takt.core.TaskMatrixPosition
import uk.co.maybeitsadam.takt.core.WorkspaceDaily
import uk.co.maybeitsadam.takt.data.db.Db

/**
 * What the inspector shows around the editor draft: the placement the draft
 * does not carry (board column, matrix, Today), the task's daily, and the time
 * logged against it. Each is written straight away rather than through Save,
 * the way the Mac's board, matrix and Today write them.
 */
data class TaskInspectorFacts(
    val kanbanColumn: String? = null,
    val matrix: TaskMatrixPosition = TaskMatrixPosition(null, null),
    /** The task's live (unarchived) daily, if it is one. */
    val daily: WorkspaceDaily? = null,
    /** Seconds of focused work, across renames (`originalTaskId`). */
    val loggedSeconds: Int = 0,
    val workBlockCount: Int = 0,
    /** Who or what it waits on. See [setWaiting]. */
    val waitingOn: String? = null,
    /** When to chase it. */
    val followUpAt: java.time.Instant? = null,
) {
    val isPlannedToday: Boolean get() = kanbanColumn == NextUpSelector.todayColumnID
}

suspend fun WorkspaceRepository.taskInspectorFacts(taskId: String): TaskInspectorFacts =
    database.read { inspectorFacts(it, taskId) }

/** [taskInspectorFacts], re-read whenever metadata, dailies or focus work change. */
fun WorkspaceRepository.observeTaskInspectorFacts(taskId: String): Flow<TaskInspectorFacts> =
    database.observe(setOf("task_metadata", "dailies", "focus_work_blocks")) { inspectorFacts(it, taskId) }

private fun inspectorFacts(db: Db, taskId: String): TaskInspectorFacts {
    val metadata = db.metadata(taskId)
    val daily = db.queryOne("SELECT * FROM dailies WHERE taskId = ? AND archivedAt IS NULL", taskId) { it.toDaily() }
    val blocks = db.query(
        "SELECT * FROM focus_work_blocks WHERE taskId = ? OR originalTaskId = ?",
        taskId, taskId,
    ) { it.toWorkBlock() }
    return TaskInspectorFacts(
        kanbanColumn = metadata?.kanbanColumn,
        matrix = TaskMatrixPosition(metadata?.matrixUrgency, metadata?.matrixImportance),
        daily = daily,
        loggedSeconds = blocks.sumOf { maxOf(0, it.seconds) },
        workBlockCount = blocks.size,
        waitingOn = metadata?.waitingOn,
        followUpAt = metadata?.waitingFollowUpAt,
    )
}
