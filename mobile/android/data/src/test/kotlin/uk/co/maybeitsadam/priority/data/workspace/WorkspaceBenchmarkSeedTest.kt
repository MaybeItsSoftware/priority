package uk.co.maybeitsadam.priority.data.workspace

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkspaceBenchmarkSeedTest {
    @Test
    fun seedsANestedOutlineOnceAndIsIdempotent() = runBlocking {
        workspace().use { ws ->
            val repo = ws.repository
            val workspace = repo.bootstrapIfNeeded()
            val list = repo.seedBenchmarkList(workspace.id, count = 600)
            val outline = repo.outline(list.id)
            assertEquals(600, outline.size)
            assertTrue("has nesting", outline.any { it.depth >= 2 })
            assertTrue("has folding points", outline.zipWithNext().any { (a, b) -> b.depth > a.depth })
            val again = repo.seedBenchmarkList(workspace.id, count = 600)
            assertEquals(list.id, again.id)
            assertEquals(600, repo.outline(list.id).size)
            assertEquals(null, repo.undoableLabel())
        }
    }
}
