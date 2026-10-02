package uk.co.maybeitsadam.priority.data

import java.io.File
import java.nio.file.Files
import java.time.Clock
import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset
import kotlinx.coroutines.Dispatchers
import uk.co.maybeitsadam.priority.data.db.WorkspaceDatabase
import uk.co.maybeitsadam.priority.data.workspace.WorkspaceRepository

/** A mutable clock, so a test can step time the way the Swift tests pass `now:`. */
class TestClock(var instant: Instant = Instant.parse("2026-10-02T09:00:00Z")) : Clock() {
    override fun getZone(): ZoneId = ZoneOffset.UTC
    override fun withZone(zone: ZoneId?): Clock = this
    override fun instant(): Instant = instant
    fun advance(seconds: Long) {
        instant = instant.plusSeconds(seconds)
    }
}

/** A throwaway database file and a repository over it. */
class TestWorkspace(
    val zone: ZoneId = ZoneOffset.UTC,
    val clock: TestClock = TestClock(),
    val file: File = Files.createTempDirectory("priority-test").resolve("priority.sqlite").toFile(),
) : AutoCloseable {
    val database: WorkspaceDatabase = WorkspaceDatabase.open(file.path, dispatcher = Dispatchers.IO)
    val repository = WorkspaceRepository(database, clock) { zone }

    override fun close() {
        database.close()
        file.parentFile.deleteRecursively()
    }
}
