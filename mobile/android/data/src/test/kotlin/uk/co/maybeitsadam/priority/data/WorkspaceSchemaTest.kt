package uk.co.maybeitsadam.priority.data

import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import androidx.sqlite.execSQL
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.priority.data.db.Db
import uk.co.maybeitsadam.priority.data.db.WorkspaceDatabase
import uk.co.maybeitsadam.priority.data.db.WorkspaceSchema

class WorkspaceSchemaTest {
    private data class SchemaObject(val type: String, val name: String, val sql: String?)

    private fun schema(db: Db): Set<SchemaObject> =
        db.query("SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") {
            SchemaObject(it.string("type"), it.string("name"), it.stringOrNull("sql"))
        }.toSet()

    /** What the fixture alone produces, executed by plain sqlite. */
    private fun fixtureSchema(): Set<SchemaObject> {
        val connection = BundledSQLiteDriver().open(":memory:")
        try {
            for (statement in WorkspaceSchema.splitStatements(WorkspaceSchema.fixtureSQL())) {
                connection.execSQL(statement)
            }
            return schema(Db(connection))
        } finally {
            connection.close()
        }
    }

    @Test
    fun freshDatabaseIsTheFixtureWithItsSyncObjects(): Unit = runBlocking {
        TestWorkspace().use { workspace ->
            val actual = workspace.database.read { schema(it) }
            val fixture = fixtureSchema()
            assertTrue("every fixture object is present unchanged", actual.containsAll(fixture))

            // The fixture is regenerated from the Mac app's database, which has
            // run v17 itself, so nothing is left for Android to add — but every
            // sync object must be there, from whichever side created it.
            assertEquals(emptySet<Pair<String, String>>(), (actual - fixture).map { it.type to it.name }.toSet())
            val present = actual.map { it.type to it.name }.toSet()
            val expected = buildSet {
                add("table" to "sync_control")
                add("table" to "sync_outbox")
                add("table" to "sync_state")
                add("index" to "sync_outbox_on_row")
                for ((table, _) in WorkspaceSchema.syncedTables) {
                    for (op in listOf("insert", "update", "delete")) add("trigger" to "sync_outbox_${table}_$op")
                }
            }
            assertTrue("missing: ${expected - present}", present.containsAll(expected))

            val migrations = workspace.database.read { it.strings("SELECT identifier FROM grdb_migrations") }
            assertEquals(18, migrations.size)
            assertTrue(WorkspaceSchema.V17_SYNC in migrations)
            assertTrue(WorkspaceSchema.V18_THEMES_AND_PREFERENCES in migrations)
            assertEquals(listOf(0L to 0L), workspace.database.read { db ->
                db.query("SELECT recording, applying FROM sync_control") { it.long("recording") to it.long("applying") }
            })
            assertEquals(1L, workspace.database.read { it.long("SELECT suppressed FROM undo_control WHERE id = 0") })
        }
    }

    @Test
    fun reopeningDoesNotApplyV17Twice(): Unit = runBlocking {
        val dir = Files.createTempDirectory("priority-schema").toFile()
        val path = dir.resolve("priority.sqlite").path
        WorkspaceDatabase.open(path).close()
        val reopened = WorkspaceDatabase.open(path)
        val count = reopened.read { it.long("SELECT COUNT(*) FROM grdb_migrations WHERE identifier = 'v17_sync'") }
        assertEquals(1L, count)
        // The fixture now carries v17 itself (regenerated from the Mac app's
        // migrated database), so the Android step stands aside and the
        // triggers are the fixture's, once each.
        assertEquals(45L, reopened.read {
            it.long("SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'sync_outbox_%' AND type = 'trigger'")
        })
        reopened.close()
        dir.deleteRecursively()
    }

    /**
     * An Android database made before v18 (the v17 fixture, so no themes or
     * preferences) takes v18 on open and comes out as the v18 fixture:
     * the same tables and triggers, to the character.
     */
    @Test
    fun aV17DatabaseUpgradesToTheV18Fixture(): Unit = runBlocking {
        val v18 = fixtureSchema()
        val dir = Files.createTempDirectory("priority-v17").toFile()
        val path = dir.resolve("priority.sqlite").path
        val connection = BundledSQLiteDriver().open(path)
        try {
            for (statement in WorkspaceSchema.splitStatements(WorkspaceSchema.fixtureSQL())) connection.execSQL(statement)
            // Roll the fixture back to v17: v18 is its two tables, their triggers and its ledger row.
            for (table in listOf("themes", "preferences")) {
                for (op in listOf("insert", "update", "delete")) connection.execSQL("DROP TRIGGER sync_outbox_${table}_$op")
                connection.execSQL("DROP TABLE $table")
            }
            connection.execSQL("DELETE FROM grdb_migrations WHERE identifier = '${WorkspaceSchema.V18_THEMES_AND_PREFERENCES}'")
        } finally {
            connection.close()
        }

        val upgraded = WorkspaceDatabase.open(path)
        try {
            assertEquals(v18, upgraded.read { schema(it) })
            val migrations = upgraded.read { it.strings("SELECT identifier FROM grdb_migrations") }
            assertEquals(WorkspaceSchema.V18_THEMES_AND_PREFERENCES, migrations.last())
        } finally {
            upgraded.close()
            dir.deleteRecursively()
        }
    }
}
