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
    db.core.allMetadata()
        .filter { it.waitingOn != null || it.waitingFollowUpAtMs != null || it.followUpOfTaskId != null }
        .associate {
            it.taskId to TaskWaitingDetails(
                waitingOn = it.waitingOn,
                followUpAt = it.waitingFollowUpAtMs?.let(Instant::ofEpochMilli),
                followUpOfTaskId = it.followUpOfTaskId,
            )
        }

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
    // The Rust core's `waiting::make_due_follow_ups`, outside the journal; it
    // reads first, so the poll that finds nothing due never takes the writer.
    return coreWrite { it.reconcileWaitingFollowUps(now.toEpochMilli()) }
}

