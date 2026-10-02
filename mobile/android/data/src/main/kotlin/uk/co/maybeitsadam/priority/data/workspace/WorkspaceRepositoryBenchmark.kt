package uk.co.maybeitsadam.priority.data.workspace

import java.time.Instant
import uk.co.maybeitsadam.priority.core.TaskList
import uk.co.maybeitsadam.priority.core.TaskStatus
import uk.co.maybeitsadam.priority.core.WorkspaceItemKind
import uk.co.maybeitsadam.priority.core.WorkspaceTask

/**
 * Fills a list called [listName] with [count] tasks in one transaction, for the
 * macrobenchmark and baseline-profile runs: a realistic outline of parents with
 * three or four levels of children, some due, some estimated, a few done.
 *
 * Not an undo step and idempotent: when the list already holds [count] tasks it
 * is returned unchanged. Returns the list.
 */
suspend fun WorkspaceRepository.seedBenchmarkList(
    workspaceId: String,
    listName: String = BENCHMARK_LIST_NAME,
    count: Int = 5_000,
    now: Instant = now(),
): TaskList = database.write { db ->
    val existing = db.queryOne(
        "SELECT * FROM task_lists WHERE workspaceId = ? AND name = ? AND isArchived = 0", workspaceId, listName,
    ) { it.toList() }
    val list = existing ?: TaskList(
        id = newId(), workspaceId = workspaceId, folderId = null, name = listName, colorHex = "#7a4de8",
        sortOrder = db.nextOrder("task_lists", "workspaceId = ? AND folderId IS ?", workspaceId, null),
        isArchived = false, systemRole = null, visibleRootTaskId = null, completedAt = null,
        createdAt = now, updatedAt = now,
    ).also { db.insert(it) }
    val present = db.int("SELECT COUNT(*) FROM tasks WHERE listId = ?", list.id) ?: 0
    if (present >= count) return@write list
    // Parent chains: every task is a root, or a child of one of the last few made,
    // so the outline has real depth and plenty of folding points.
    val recent = ArrayDeque<Pair<String, Int>>()
    val order = HashMap<String?, Int>()
    for (index in present until count) {
        val parent = when {
            index % 9 == 0 || recent.isEmpty() -> null
            else -> recent.filter { it.second < 4 }.randomOrNullStable(index)?.first
        }
        val depth = if (parent == null) 0 else (recent.first { it.first == parent }.second + 1)
        val sort = order.getOrDefault(parent, 0)
        order[parent] = sort + 1
        val due = if (index % 7 == 0) now.plusSeconds((index % 21 - 7) * 86_400L) else null
        val done = index % 13 == 0
        val task = WorkspaceTask(
            id = newId(), listId = list.id, parentTaskId = parent, title = "Benchmark task ${index + 1}",
            notes = if (index % 5 == 0) "Notes for task ${index + 1}" else "",
            status = if (done) TaskStatus.COMPLETED else TaskStatus.OPEN, sortOrder = sort, dueAt = due,
            estimateSeconds = if (index % 3 == 0) (index % 8 + 1) * 15 * 60 else null, sourceSystem = null,
            sourceId = null, itemKind = WorkspaceItemKind.TASK, isPromoted = null, archivedAt = null,
            completedAt = if (done) now else null, createdAt = now.minusSeconds(index.toLong()), updatedAt = now,
        )
        db.insert(task)
        recent.addLast(task.id to depth)
        if (recent.size > 12) recent.removeFirst()
    }
    list
}

const val BENCHMARK_LIST_NAME = "Benchmark 5k"

/** A deterministic pick, so the seeded outline is the same shape on every run. */
private fun <T> List<T>.randomOrNullStable(seed: Int): T? = if (isEmpty()) null else this[(seed * 31 + 7) % size]
