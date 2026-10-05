package uk.co.maybeitsadam.takt.data.workspace

import androidx.sqlite.SQLiteConnection
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import java.time.Instant
import java.time.ZoneOffset
import org.junit.Assert.assertEquals
import uk.co.maybeitsadam.takt.data.TestClock
import uk.co.maybeitsadam.takt.data.TestWorkspace
import uk.co.maybeitsadam.takt.data.db.Db

// Helpers for the ports of workspace-tests/*.swift.

/** A workspace whose clock ticks a millisecond per reading, as the Swift tests' `Date.now` does. */
fun workspace(): TestWorkspace = TestWorkspace(clock = TestClock(stepMillis = 1))

/** `Date(timeIntervalSince1970:)`. */
fun epoch(seconds: Long): Instant = Instant.ofEpochSecond(seconds)

val UTC: ZoneOffset = ZoneOffset.UTC

/** XCTAssertThrowsError: runs [block] and returns what it threw. */
suspend fun thrown(block: suspend () -> Unit): Throwable {
    try {
        block()
    } catch (error: Throwable) {
        return error
    }
    throw AssertionError("Expected an error to be thrown")
}

suspend fun assertStoreError(expected: WorkspaceStoreError, block: suspend () -> Unit) {
    val error = thrown(block)
    assertEquals(expected, (error as? WorkspaceStoreException)?.error ?: error)
}

suspend fun assertEditorError(expected: TaskEditorError, block: suspend () -> Unit) {
    val error = thrown(block)
    assertEquals(expected, (error as? TaskEditorException)?.error ?: error)
}

/** `draft.values.x = y`, for the immutable Kotlin draft. */
fun TaskEditorDraft.edit(change: TaskEditorValues.() -> TaskEditorValues): TaskEditorDraft =
    copy(values = values.change())

/** Another process's connection to the same file, as the Swift tests open a `DatabaseQueue`. */
fun <T> TestWorkspace.otherConnection(block: (Db) -> T): T {
    val connection: SQLiteConnection = BundledSQLiteDriver().open(file.path)
    try {
        val db = Db(connection)
        db.execute("PRAGMA foreign_keys = ON")
        return block(db)
    } finally {
        connection.close()
    }
}

/**
 * What `importTasks` leaves behind for a two-task import (a root and one child,
 * both carrying a source identity), written directly because import is not
 * ported. [registerRoot] mirrors `registerVisibleRoot`, which claims the root
 * when its name matches the list's.
 */
suspend fun TestWorkspace.importedList(
    workspaceId: String,
    name: String,
    rootTitle: String = name,
    childTitle: String = "Proposal",
    sourceSystem: String = "checkvist",
    registerRoot: Boolean = true,
    rootSourceId: String = "root",
    childSourceId: String = "child",
): uk.co.maybeitsadam.takt.core.TaskList {
    val listId = newId()
    val rootId = newId()
    val now = clock.instant()
    database.write { db ->
        val order = db.int("SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM task_lists WHERE workspaceId = ? AND folderId IS NULL", workspaceId)
        db.execute(
            "INSERT INTO task_lists (id, workspaceId, name, sortOrder, isArchived, createdAt, updatedAt, visibleRootTaskId) " +
                "VALUES (?, ?, ?, ?, 0, ?, ?, NULL)",
            listId, workspaceId, name, order, now, now,
        )
        db.execute(
            "INSERT INTO tasks (id, listId, title, status, sortOrder, createdAt, updatedAt, sourceSystem, sourceId) " +
                "VALUES (?, ?, ?, 'open', 0, ?, ?, ?, ?)",
            rootId, listId, rootTitle, now, now, sourceSystem, rootSourceId,
        )
        db.execute(
            "INSERT INTO tasks (id, listId, parentTaskId, title, status, sortOrder, createdAt, updatedAt, sourceSystem, sourceId) " +
                "VALUES (?, ?, ?, ?, 'open', 0, ?, ?, ?, ?)",
            newId(), listId, rootId, childTitle, now, now, sourceSystem, childSourceId,
        )
        if (registerRoot) db.execute("UPDATE task_lists SET visibleRootTaskId = ? WHERE id = ?", rootId, listId)
    }
    return repository.lists(workspaceId, includingArchived = true).first { it.id == listId }
}

/** A second store over the same file, as the Swift tests reopen `WorkspaceStore(databaseURL:)`. */
suspend fun <T> TestWorkspace.reopened(block: suspend (WorkspaceRepository) -> T): T {
    val database = uk.co.maybeitsadam.takt.data.db.WorkspaceDatabase.open(file.path)
    try {
        return block(WorkspaceRepository(database, clock) { zone })
    } finally {
        database.close()
    }
}
