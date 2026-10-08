package uk.co.maybeitsadam.takt.data.workspace

import java.time.Instant
import kotlinx.coroutines.flow.Flow
import uk.co.maybeitsadam.takt.core.TaskStatus
import uk.co.maybeitsadam.takt.core.WaitingFollowUp
import uk.co.maybeitsadam.takt.core.WaitingTaskState
import uk.co.maybeitsadam.takt.data.db.Db

// Waiting on (WorkspaceStore+Waiting.swift): a tag naming who or what a task
// waits on, a time to chase it, and the follow-up task that lands in Today at
// that time if the task is still waiting. `WaitingFollowUp` in :core decides;
// this file applies it, row for row as the Mac does, so the follow-up both
// devices make is one row once sync has merged them.

/** What a card shows about a task that is waiting, or that chases one. */
data class TaskWaitingDetails(
    val waitingOn: String? = null,
    val followUpAt: Instant? = null,
    /** On a follow-up task: the waiting task it chases. */
    val followUpOfTaskId: String? = null,
)

private fun readWaitingDetails(db: Db): Map<String, TaskWaitingDetails> =
    db.query(
        "SELECT taskId, waitingOn, waitingFollowUpAt, followUpOfTaskId FROM task_metadata " +
            "WHERE waitingOn IS NOT NULL OR waitingFollowUpAt IS NOT NULL OR followUpOfTaskId IS NOT NULL",
    ) {
        it.string("taskId") to TaskWaitingDetails(
            waitingOn = it.stringOrNull("waitingOn"),
            followUpAt = it.instantOrNull("waitingFollowUpAt"),
            followUpOfTaskId = it.stringOrNull("followUpOfTaskId"),
        )
    }.toMap()

/** Every task with a waiting tag, a follow-up time, or a source it chases. A small set, read whole. */
suspend fun WorkspaceRepository.waitingDetails(): Map<String, TaskWaitingDetails> = database.read(::readWaitingDetails)

fun WorkspaceRepository.observeWaitingDetails(): Flow<Map<String, TaskWaitingDetails>> =
    database.observe(setOf("task_metadata"), ::readWaitingDetails)

/**
 * Sets what a task waits on and when to chase it, and files it in Waiting on
 * if it is not there already. Null clears either. One undo step, which
 * includes the follow-up when the time set has already passed.
 */
suspend fun WorkspaceRepository.setWaiting(
    taskId: String,
    waitingOn: String?,
    followUpAt: Instant?,
    now: Instant = now(),
) {
    // The Rust core's `waiting::set_waiting`, which keeps the follow-up time
    // to the minute and makes a follow-up already due in the same step.
    coreWrite { it.setWaiting(taskId, waitingOn, followUpAt?.toEpochMilli(), now.toEpochMilli()) }
}

/**
 * Makes every follow-up that has come due. Not an undo step, like the Mac's
 * habit pass: nobody asked for it, and undoing it would only have the next
 * pass make it again. Returns whether anything was made.
 */
suspend fun WorkspaceRepository.reconcileWaitingFollowUps(now: Instant = now()): Boolean {
    // A read first, so the poll that finds nothing due never takes the writer.
    val due = database.read { db -> waitingStates(db, null).any { WaitingFollowUp.dueFollowUp(it, now) != null } }
    if (!due) return false
    // The Rust core's `waiting::make_due_follow_ups`, outside the journal.
    return coreWrite { it.reconcileWaitingFollowUps(now.toEpochMilli()) }
}

/** The open waiting tasks with a follow-up time, as the engine reads them. */
private fun waitingStates(db: Db, taskId: String?): List<WaitingTaskState> {
    var sql = "SELECT t.id, t.title, t.status, m.kanbanColumn, m.waitingOn, m.waitingFollowUpAt, " +
        "m.waitingFollowUpTaskId FROM task_metadata m JOIN tasks t ON t.id = m.taskId " +
        "WHERE m.waitingFollowUpAt IS NOT NULL AND m.kanbanColumn = ? AND t.status = ?"
    val args = mutableListOf<Any?>(WaitingFollowUp.WAITING_COLUMN_ID, TaskStatus.OPEN.raw)
    if (taskId != null) {
        sql += " AND t.id = ?"
        args += taskId
    }
    return db.query(sql, *args.toTypedArray()) {
        WaitingTaskState(
            taskId = it.string("id"),
            title = it.string("title"),
            isOpen = it.string("status") == TaskStatus.OPEN.raw,
            column = it.stringOrNull("kanbanColumn"),
            waitingOn = it.stringOrNull("waitingOn"),
            followUpAt = it.instantOrNull("waitingFollowUpAt"),
            madeFollowUpTaskId = it.stringOrNull("waitingFollowUpTaskId"),
        )
    }
}

