package uk.co.maybeitsadam.takt.debug

import java.nio.file.Files
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.data.db.WorkspaceDatabase
import uk.co.maybeitsadam.takt.data.workspace.WorkspaceRepository

class DemoSeedTest {
    private val zone = ZoneId.of("Europe/London")
    private val today = LocalDate.of(2026, 10, 19)

    @Test
    fun seedsAnEmptyWorkspaceOnceWithDatesFromToday(): Unit = runBlocking {
        val dir = Files.createTempDirectory("demo-seed").toFile()
        val database = WorkspaceDatabase.open(dir.resolve("priority.sqlite").path, dispatcher = Dispatchers.IO)
        try {
            val repository = WorkspaceRepository(database) { zone }
            val workspace = repository.bootstrapIfNeeded()
            assertTrue(DemoSeed.seedIfEmpty(repository, workspace.id, zone, today))

            val lists = repository.lists(workspace.id).map { it.name }.toSet()
            assertEquals(setOf("Inbox", "Work", "Home", "Reading"), lists)
            val work = repository.lists(workspace.id).first { it.name == "Work" }
            val polish = repository.listTree(work.id).tasks.first { it.title == "Polish the outline rows" }
            assertEquals(today.atStartOfDay(zone).toInstant(), polish.dueAt)
            assertTrue(repository.daily(polish.id) != null)
            // Each subtask lands under its parent in Work, not in a list named by its title.
            val tree = repository.listTree(work.id).tasks
            val ship = tree.first { it.title == "Ship the iOS app" }
            assertEquals(
                listOf("Polish the outline rows", "Write the README", "Take screenshots", "Submit for review"),
                tree.filter { it.parentTaskId == ship.id }.map { it.title },
            )
            assertEquals("in-progress", repository.kanbanColumn(tree.first { it.title == "Reply to Sam about the roadmap" }.id))

            // A second launch with the extra leaves the workspace alone.
            assertFalse(DemoSeed.seedIfEmpty(repository, workspace.id, zone, today))
            assertEquals(4, repository.lists(workspace.id).size)
        } finally {
            database.close()
            dir.deleteRecursively()
        }
    }
}
