package uk.co.maybeitsadam.takt.data.workspace

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Port of workspace-tests/WorkspaceInboxTests.swift.
 * `testMigrationClaimsTheOldestInboxAndLeavesLaterOnesAlone` is not ported: it
 * rewinds GRDB's v6 migration, and the Android side creates the schema from the
 * finished fixture rather than migrating.
 */
class WorkspaceInboxTest {
    @Test
    fun bootstrapGivesTheInboxItsRole(): Unit = runBlocking {
        workspace().use { w ->
            val workspace = w.repository.bootstrapIfNeeded()
            val inbox = w.repository.inbox(workspace.id)!!
            assertEquals("Inbox", inbox.name)
            assertTrue(inbox.isSystemList)
        }
    }

    @Test
    fun renamingTheInboxKeepsItTheInbox(): Unit = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded()
            val inbox = store.inbox(workspace.id)!!
            store.updateList(inbox.id, "Capture", null)
            val found = store.inbox(workspace.id)!!
            assertEquals(inbox.id, found.id)
            assertEquals("Capture", found.name)
        }
    }

    @Test
    fun theInboxCannotBeArchivedOrDeleted(): Unit = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded()
            val inbox = store.inbox(workspace.id)!!
            assertStoreError(WorkspaceStoreError.SYSTEM_LIST_IS_PERMANENT) { store.setListArchived(true, inbox.id) }
            assertStoreError(WorkspaceStoreError.SYSTEM_LIST_IS_PERMANENT) { store.deleteList(inbox.id) }
            assertEquals(listOf(inbox.id), store.lists(workspace.id).map { it.id })
        }
    }

    @Test
    fun aWorkspaceWithNoInboxGetsOneOnNextLaunch(): Unit = runBlocking {
        workspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded()
            val inbox = store.inbox(workspace.id)!!
            w.otherConnection { it.execute("DELETE FROM task_lists WHERE id = ?", inbox.id) }
            assertNull(store.inbox(workspace.id))
            store.bootstrapIfNeeded()
            val replacement = store.inbox(workspace.id)!!
            assertEquals("Inbox", replacement.name)
            assertNotEquals(inbox.id, replacement.id)
        }
    }
}
