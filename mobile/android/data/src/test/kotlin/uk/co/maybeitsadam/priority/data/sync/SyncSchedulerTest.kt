package uk.co.maybeitsadam.priority.data.sync

import java.nio.file.Files
import kotlin.time.Duration.Companion.milliseconds
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.priority.data.db.WorkspaceDatabase
import uk.co.maybeitsadam.priority.data.workspace.WorkspaceRepository

class SyncSchedulerTest {
    @Test
    fun aLocalWriteIsPushedOnceThingsGoQuiet(): Unit = runBlocking {
        val dir = Files.createTempDirectory("scheduler").toFile()
        val database = WorkspaceDatabase.open(dir.resolve("a.sqlite").path)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            val server = InMemorySyncServer()
            val repository = WorkspaceRepository(database)
            val workspace = repository.bootstrapIfNeeded()
            val store = SyncStore(database)
            store.beginSync("a", "memory://")
            val engine = SyncEngine(store, server.transport("a"), "a")
            val scheduler = SyncScheduler(engine, scope, debounce = 50.milliseconds)
            assertTrue(scheduler.syncNow())
            val before = server.rowCount

            scheduler.watchLocalWrites(store)
            delay(100)
            repository.createTask(listId = repository.inbox(workspace.id)!!.id, title = "pushed")
            withTimeout(5_000) {
                while (server.rowCount == before) delay(20)
            }
            assertEquals(before + 1, server.rowCount)
            assertEquals(0, store.pendingChanges().changes.size)
        } finally {
            scope.cancel()
            database.close()
            dir.deleteRecursively()
        }
    }
}
