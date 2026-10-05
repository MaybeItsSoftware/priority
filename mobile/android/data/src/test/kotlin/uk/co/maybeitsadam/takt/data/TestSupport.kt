package uk.co.maybeitsadam.takt.data

import java.io.File
import java.nio.file.Files
import java.time.Clock
import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset
import kotlinx.coroutines.Dispatchers
import uk.co.maybeitsadam.takt.data.db.WorkspaceDatabase
import uk.co.maybeitsadam.takt.data.workspace.WorkspaceRepository

/** A mutable clock, so a test can step time the way the Swift tests pass `now:`. */
class TestClock(
    var instant: Instant = Instant.parse("2026-10-02T09:00:00Z"),
    /** Milliseconds each reading moves the clock on, so default `now`s stay distinct like a real clock's. */
    var stepMillis: Long = 0,
) : Clock() {
    override fun getZone(): ZoneId = ZoneOffset.UTC
    override fun withZone(zone: ZoneId?): Clock = this
    override fun instant(): Instant = instant.also { instant = instant.plusMillis(stepMillis) }
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
