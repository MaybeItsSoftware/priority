package uk.co.maybeitsadam.takt.data.workspace

import java.time.Instant
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.core.SyncIncomingRow
import uk.co.maybeitsadam.takt.core.SyncValue
import uk.co.maybeitsadam.takt.data.TestWorkspace
import uk.co.maybeitsadam.takt.data.sync.SyncStore

/**
 * What holds now is the workspace's (`focus_contexts`), synced since
 * `v28_synced_focus_context`: the phone reads and writes the row the Mac,
 * the iPhone and the CLI do, pushes it whole, and takes another device's.
 */
class WorkspaceFocusContextTest {
    private val now: Instant = Instant.ofEpochMilli(1_789_560_000_000)

    @Test
    fun aContextIsSavedStampedAndObserved(): Unit = runBlocking {
        TestWorkspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded(now = now)
            assertNull(store.focusContext(workspace.id))
            val campus = store.createCondition(workspace.id, "Campus", "Location", now = now)
            assertTrue(store.saveFocusContext(workspace.id, emptyFocusContext().copy(conditionIds = listOf(campus.id)), now))
            assertFalse("the same answer again writes nothing",
                store.saveFocusContext(workspace.id, emptyFocusContext().copy(conditionIds = listOf(campus.id)), now.plusSeconds(60)))
            val saved = store.observeFocusContext(workspace.id).first()
            assertNotNull(saved)
            assertEquals(listOf(campus.id), saved!!.conditionIds)
            assertEquals(now.toEpochMilli(), saved.conditionsSetAtMs)
        }
    }

    @Test
    fun thePhonesOwnContextMovesInOnlyWhenTheWorkspaceHasNone(): Unit = runBlocking {
        TestWorkspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded(now = now)
            assertFalse("nothing to move", store.adoptPhoneFocusContext(workspace.id, emptySet(), null, now))
            assertTrue(store.adoptPhoneFocusContext(workspace.id, setOf("b", "a"), "finish", now))
            val moved = store.focusContext(workspace.id)!!
            assertEquals(listOf("a", "b"), moved.conditionIds)
            assertEquals("finish", moved.mode)
            assertFalse("the workspace's answer stands", store.adoptPhoneFocusContext(workspace.id, setOf("c"), null, now))
            assertEquals(listOf("a", "b"), store.focusContext(workspace.id)!!.conditionIds)
        }
    }

    @Test
    fun theContextIsPushedWholeAndTakenFromAnotherDevice(): Unit = runBlocking {
        TestWorkspace().use { w ->
            val store = w.repository
            val workspace = store.bootstrapIfNeeded(now = now)
            val sync = SyncStore(w.database)
            sync.beginSync("device-a", "https://sync.example")
            sync.enqueueSnapshot(w.clock.instant())
            sync.pendingChanges(10_000).throughSeq?.let { sync.acknowledge(it) }

            store.saveFocusContext(workspace.id, emptyFocusContext().copy(conditionIds = listOf("campus")), now)
            store.saveFocusContext(workspace.id, emptyFocusContext().copy(conditionIds = listOf("campus"), mode = "finish"), now)
            val pending = sync.pendingChanges()
            val change = pending.changes.single { it.table == "focus_contexts" }
            assertEquals(workspace.id, change.rowId)
            // Only the mode moved last, yet every column goes: the last
            // device to say where you are wins the whole answer.
            assertEquals(SyncValue.Text("""["campus"]"""), change.values["conditionIdsJSON"])
            assertEquals(SyncValue.Text("finish"), change.values["mode"])
            assertTrue(change.values.containsKey("conditionsSetAt"))
            sync.acknowledge(pending.throughSeq!!)

            sync.applyRemoteRows(
                listOf(
                    SyncIncomingRow(
                        "focus_contexts", workspace.id, false,
                        mapOf(
                            "workspaceId" to SyncValue.Text(workspace.id),
                            "conditionIdsJSON" to SyncValue.Text("""["home"]"""),
                            "conditionsSetAt" to SyncValue.Text("2026-10-14 08:00:00.000"),
                            "availableUntil" to SyncValue.Null,
                            "expiresAt" to SyncValue.Null,
                            "mode" to SyncValue.Text("progress"),
                            "suggestedIdsJSON" to SyncValue.Text("[]"),
                            "updatedAt" to SyncValue.Text("2026-10-14 08:00:00.000"),
                        ),
                    ),
                ),
                cursor = 2, hlc = null, now = w.clock.instant(),
            )
            val taken = store.focusContext(workspace.id)!!
            assertEquals(listOf("home"), taken.conditionIds)
            assertEquals("progress", taken.mode)
            assertTrue("applied rows are not echoed back", sync.pendingChanges().changes.isEmpty())
        }
    }
}
