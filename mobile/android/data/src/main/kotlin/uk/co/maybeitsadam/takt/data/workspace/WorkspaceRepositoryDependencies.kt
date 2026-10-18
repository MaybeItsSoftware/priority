package uk.co.maybeitsadam.takt.data.workspace

import java.time.Instant
import kotlinx.coroutines.flow.Flow
import uk.co.maybeitsadam.takt.core.WorkspaceTask
import uk.co.maybeitsadam.takt.data.db.Db

// Task dependencies: a task that waits on others until they are done. The rule
// is the Rust core's (`dependencies`): a task is blocked while it is open and
// waits on an open task; the core's reads already sink blocked tasks below
// their unblocked siblings and keep them out of next up. Here are the writes
// and the reads a screen draws from.

/** What the inspector shows of a task's dependencies. */
data class TaskDependencies(
    /** What it waits on, open ones first. */
    val blockers: List<WorkspaceTask> = emptyList(),
    /** What waits on it, open ones first. */
    val blocking: List<WorkspaceTask> = emptyList(),
    /** Whether it is open and waiting on an open task now. */
    val isBlocked: Boolean = false,
)

/** The tables a read that orders tasks, or greys them, depends on. */
internal val TASK_ORDER_TABLES: Set<String> = setOf("tasks", "task_dependencies")

/**
 * Makes [taskId] wait on [blockedByTaskId] as one "Add Blocker" step. Whether
 * anything changed: an edge already there is not an error. A task waiting on
 * itself, or an edge that would close a cycle, fails with
 * [WorkspaceStoreError.DEPENDENCY_CYCLE].
 */
suspend fun WorkspaceRepository.addBlocker(taskId: String, blockedByTaskId: String, now: Instant = now()): Boolean =
    coreWrite { it.addTaskBlocker(taskId, blockedByTaskId, now.toEpochMilli()) }

/** Stops [taskId] waiting on [blockedByTaskId] as one "Remove Blocker" step. Whether there was such an edge. */
suspend fun WorkspaceRepository.removeBlocker(taskId: String, blockedByTaskId: String): Boolean =
    coreWrite { it.removeTaskBlocker(taskId, blockedByTaskId) }

/** The tasks [taskId] waits on, open ones first. */
suspend fun WorkspaceRepository.blockers(taskId: String): List<WorkspaceTask> =
    coreRead { core -> core.taskBlockers(taskId).map { it.toTask() } }

/** The tasks waiting on [taskId], open ones first. */
suspend fun WorkspaceRepository.blocking(taskId: String): List<WorkspaceTask> =
    coreRead { core -> core.tasksBlockedBy(taskId).map { it.toTask() } }

/** Every open task waiting on an open task: what the screens draw greyed. */
suspend fun WorkspaceRepository.blockedTaskIds(): Set<String> = coreRead { it.blockedTaskIds().toSet() }

/**
 * Of [among], the open tasks whose start is still to come (the Rust core's
 * `buried::buried_task_ids`) and when each starts: what a screen draws greyed
 * with `starts Mon` beside it.
 */
suspend fun WorkspaceRepository.buriedStarts(among: Collection<String>, now: Instant = now()): Map<String, Instant> =
    database.read { db ->
        val buried = db.core.buriedTaskIds(now.toEpochMilli()).toHashSet()
        among.filter { it in buried }.mapNotNull { id -> db.metadata(id)?.startAt?.let { id to it } }.toMap()
    }

/** [blockedTaskIds], re-read when tasks or their dependencies change (a completion unblocks). */
fun WorkspaceRepository.observeBlockedTaskIds(): Flow<Set<String>> =
    database.observe(TASK_ORDER_TABLES) { it.core.blockedTaskIds().toSet() }

suspend fun WorkspaceRepository.isBlocked(taskId: String): Boolean = coreRead { it.isTaskBlocked(taskId) }

suspend fun WorkspaceRepository.taskDependencies(taskId: String): TaskDependencies = database.read { dependencies(it, taskId) }

/** [taskDependencies], re-read when tasks or their dependencies change. */
fun WorkspaceRepository.observeTaskDependencies(taskId: String): Flow<TaskDependencies> =
    database.observe(TASK_ORDER_TABLES) { dependencies(it, taskId) }

private fun dependencies(db: Db, taskId: String) = TaskDependencies(
    blockers = db.core.taskBlockers(taskId).map { it.toTask() },
    blocking = db.core.tasksBlockedBy(taskId).map { it.toTask() },
    isBlocked = db.core.isTaskBlocked(taskId),
)
