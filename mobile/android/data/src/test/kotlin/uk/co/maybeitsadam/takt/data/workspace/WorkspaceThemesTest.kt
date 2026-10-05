package uk.co.maybeitsadam.takt.data.workspace

import java.time.Instant
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.core.SyncIncomingRow
import uk.co.maybeitsadam.takt.core.SyncValue
import uk.co.maybeitsadam.takt.data.TestWorkspace
import uk.co.maybeitsadam.takt.data.sync.SyncOutgoingChange
import uk.co.maybeitsadam.takt.data.sync.SyncStore

/** Mirrors workspace-tests/WorkspaceThemesTests.swift: synced, unjournalled, quiet when nothing changes. */
class WorkspaceThemesTest {
    private val selected = WorkspacePreferenceKey.THEME_SELECTED
    private val appearance = WorkspacePreferenceKey.THEME_APPEARANCE

    @Test
    fun aThemeIsStoredReplacedAndDeleted(): Unit = runBlocking {
        TestWorkspace().use { w ->
            val store = w.repository.also { it.bootstrapIfNeeded() }
            val first = Instant.ofEpochSecond(1_000)
            assertEquals(emptyList<StoredTheme>(), store.themes())
            assertTrue(store.upsertTheme("user.dusk", """{"name":"Dusk"}""", first))
            assertTrue(store.upsertTheme("user.amber", "{}", first))
            assertEquals(listOf("user.amber", "user.dusk"), store.themes().map { it.id })

            val later = first.plusSeconds(60)
            assertFalse("the same text is not a change", store.upsertTheme("user.dusk", """{"name":"Dusk"}""", later))
            assertEquals(first, store.themes().first { it.id == "user.dusk" }.updatedAt)

            assertTrue(store.upsertTheme("user.dusk", """{"name":"Dusker"}""", later))
            val dusk = store.themes().first { it.id == "user.dusk" }
            assertEquals("""{"name":"Dusker"}""", dusk.json)
            assertEquals(later, dusk.updatedAt)

            assertTrue(store.deleteTheme("user.dusk"))
            assertFalse(store.deleteTheme("user.dusk"))
            assertEquals(listOf("user.amber"), store.themes().map { it.id })
            assertEquals(listOf("user.amber"), store.observeThemes().first().map { it.id })
        }
    }

    @Test
    fun aPreferenceIsSetChangedAndCleared(): Unit = runBlocking {
        TestWorkspace().use { w ->
            val store = w.repository.also { it.bootstrapIfNeeded() }
            assertNull(store.preference(selected))
            assertTrue(store.setPreference(selected, "user.dusk"))
            assertFalse(store.setPreference(selected, "user.dusk"))
            assertEquals("user.dusk", store.preference(selected))

            assertTrue(store.setPreference(appearance, "dark"))
            assertTrue(store.setPreference(selected, null))
            assertFalse(store.setPreference(selected, null))
            assertNull(store.preference(selected))

            val all = store.preferences()
            assertEquals("a cleared key is kept, as null", 2, all.size)
            assertEquals("dark", all[appearance])
            assertTrue(all.containsKey(selected) && all[selected] == null)
            assertEquals(all, store.observePreferences().first())
        }
    }

    @Test
    fun themesAndPreferencesAreNotUndoSteps(): Unit = runBlocking {
        TestWorkspace().use { w ->
            val store = w.repository.also { it.bootstrapIfNeeded() }
            val before = store.undoableLabel()
            store.upsertTheme("user.dusk", "{}")
            store.setPreference(selected, "user.dusk")
            assertEquals(before, store.undoableLabel())
            val journalled = w.database.read {
                it.long("SELECT COUNT(*) FROM change_log WHERE tableName IN ('themes', 'preferences')")
            }
            assertEquals(0L, journalled)
        }
    }

    @Test
    fun themesAndPreferencesReachTheSyncOutbox(): Unit = runBlocking {
        TestWorkspace().use { w ->
            val store = w.repository.also { it.bootstrapIfNeeded() }
            val sync = SyncStore(w.database)
            sync.beginSync("device-a", "https://sync.example")
            sync.enqueueSnapshot(w.clock.instant())
            sync.pendingChanges(10_000).throughSeq?.let { sync.acknowledge(it) }

            store.upsertTheme("user.dusk", """{"name":"Dusk"}""")
            store.upsertTheme("user.dusk", """{"name":"Dusk"}""")
            store.setPreference(selected, "user.dusk")

            val pending = sync.pendingChanges()
            assertEquals(listOf("preferences", "themes"), pending.changes.map { it.table }.sorted())
            val theme = pending.changes.first { it.table == "themes" }
            assertEquals("user.dusk", theme.rowId)
            assertEquals(SyncValue.Text("""{"name":"Dusk"}"""), theme.values["json"])
            val preference = pending.changes.first { it.table == "preferences" }
            assertEquals(selected, preference.rowId)
            assertEquals(SyncValue.Text("user.dusk"), preference.values["value"])

            sync.acknowledge(pending.throughSeq!!)
            store.deleteTheme("user.dusk")
            val deletion = sync.pendingChanges().changes.first()
            assertEquals(SyncOutgoingChange.Operation.DELETE, deletion.operation)
            assertEquals("user.dusk", deletion.rowId)
        }
    }

    @Test
    fun theSnapshotIncludesThemesAndPreferences(): Unit = runBlocking {
        TestWorkspace().use { w ->
            val store = w.repository.also { it.bootstrapIfNeeded() }
            store.upsertTheme("user.dusk", "{}")
            store.setPreference(appearance, "light")
            val sync = SyncStore(w.database)
            sync.beginSync("device-a", "https://sync.example")
            sync.enqueueSnapshot(w.clock.instant())
            val tables = sync.pendingChanges(10_000).changes.map { it.table }.toSet()
            assertTrue(tables.toString(), tables.containsAll(setOf("themes", "preferences")))
        }
    }

    @Test
    fun remoteRowsLandInBothTables(): Unit = runBlocking {
        TestWorkspace().use { w ->
            val store = w.repository.also { it.bootstrapIfNeeded() }
            val sync = SyncStore(w.database)
            sync.beginSync("device-a", "https://sync.example")
            sync.enqueueSnapshot(w.clock.instant())
            sync.pendingChanges(10_000).throughSeq?.let { sync.acknowledge(it) }
            val stamp = SyncValue.Text("2026-10-02 09:00:00.000")
            sync.applyRemoteRows(
                listOf(
                    SyncIncomingRow(
                        "themes", "user.remote", false,
                        mapOf("id" to SyncValue.Text("user.remote"), "json" to SyncValue.Text("{}"), "updatedAt" to stamp),
                    ),
                    SyncIncomingRow(
                        "preferences", selected, false,
                        mapOf("key" to SyncValue.Text(selected), "value" to SyncValue.Text("user.remote"), "updatedAt" to stamp),
                    ),
                ),
                cursor = 2, hlc = null, now = w.clock.instant(),
            )
            assertEquals(listOf("user.remote"), store.themes().map { it.id })
            assertEquals("user.remote", store.preference(selected))
            assertEquals("applied rows are not echoed back", emptyList<SyncOutgoingChange>(), sync.pendingChanges().changes)
        }
    }
}
