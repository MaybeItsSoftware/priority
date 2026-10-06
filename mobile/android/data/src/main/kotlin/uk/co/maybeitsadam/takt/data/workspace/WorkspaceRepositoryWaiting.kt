package uk.co.maybeitsadam.takt.data.workspace

import java.time.Instant
import kotlinx.coroutines.flow.Flow
import uk.co.maybeitsadam.takt.core.NextUpSelector
import uk.co.maybeitsadam.takt.core.TaskStatus
import uk.co.maybeitsadam.takt.core.WaitingFollowUp
import uk.co.maybeitsadam.takt.core.WaitingTaskState
import uk.co.maybeitsadam.takt.core.WorkspaceItemKind
import uk.co.maybeitsadam.takt.core.WorkspaceTask
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
    val tag = WaitingFollowUp.normalizedTag(waitingOn)
    // Whole minutes: the field takes nothing finer, and the follow-up's id is derived from this instant.
    val minute = followUpAt?.let { Instant.ofEpochSecond(Math.floorDiv(it.epochSecond, 60L) * 60L) }
    journalledWrite("Waiting On") { db ->
        db.task(taskId) ?: fail(WorkspaceStoreError.MISSING_TASK)
        var record = db.metadata(taskId) ?: emptyMetadata(taskId, now)
        if (record.kanbanColumn != WaitingFollowUp.WAITING_COLUMN_ID) {
            // Leaving Today drops the place in the day, as `setPlannedForToday` does.
            val focusRank = if (record.kanbanColumn == NextUpSelector.todayColumnID) null else record.focusRank
            record = record.copy(kanbanColumn = WaitingFollowUp.WAITING_COLUMN_ID, focusRank = focusRank)
        }
        db.save(record.copy(waitingOn = tag, waitingFollowUpAt = minute, updatedAt = now))
        for (state in waitingStates(db, taskId)) makeFollowUp(db, state, now)
    }
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
    return database.write { db ->
        var made = false
        for (state in waitingStates(db, null)) if (makeFollowUp(db, state, now)) made = true
        made
    }
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

/**
 * Makes [state]'s follow-up if it is due: a sibling of the waiting task, in
 * Today, due at the follow-up time, linked back by `followUpOfTaskId`. A row
 * with the same id already there — another device made it and sync brought
 * it — is kept, and only recorded as made.
 */
private fun makeFollowUp(db: Db, state: WaitingTaskState, now: Instant): Boolean {
    val plan = WaitingFollowUp.dueFollowUp(state, now) ?: return false
    val source = db.task(state.taskId) ?: return false
    if (db.task(plan.taskId) == null) {
        val order = db.nextOrder("tasks", "listId = ? AND parentTaskId IS ?", source.listId, source.parentTaskId)
        db.insert(
            WorkspaceTask(
                id = plan.taskId, listId = source.listId, parentTaskId = source.parentTaskId, title = plan.title,
                notes = "", status = TaskStatus.OPEN, sortOrder = order, dueAt = plan.dueAt, estimateSeconds = null,
                sourceSystem = null, sourceId = null, itemKind = WorkspaceItemKind.TASK, isPromoted = null,
                archivedAt = null, completedAt = null, createdAt = now, updatedAt = now,
            ),
        )
        db.execute(
            "INSERT INTO task_metadata(taskId, tagsJSON, externalLinksJSON, kanbanColumn, followUpOfTaskId, updatedAt) " +
                "VALUES (?, '[]', '[]', ?, ?, ?) ON CONFLICT(taskId) DO UPDATE SET " +
                "kanbanColumn = excluded.kanbanColumn, followUpOfTaskId = excluded.followUpOfTaskId, " +
                "updatedAt = excluded.updatedAt",
            plan.taskId, WaitingFollowUp.FOLLOW_UP_COLUMN_ID, source.id, now,
        )
    }
    db.execute(
        "UPDATE task_metadata SET waitingFollowUpTaskId = ?, updatedAt = ? WHERE taskId = ?",
        plan.taskId, now, source.id,
    )
    return true
}
