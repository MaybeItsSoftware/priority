package uk.co.maybeitsadam.takt.data

import androidx.sqlite.SQLiteConnection
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import androidx.sqlite.execSQL
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.data.db.Db
import uk.co.maybeitsadam.takt.data.db.WorkspaceDatabase
import uk.co.maybeitsadam.takt.data.db.WorkspaceSchema

/**
 * Android opens through the Rust core's migrations (core/src/schema). These
 * hold the result to the fixture the core generates, on a new database and on
 * Android databases from before each of the last three migrations.
 */
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
            for (statement in SchemaFixture.splitStatements(SchemaFixture.sql())) {
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

            // The core migrates every client the same way and the fixture is
            // generated from it, so nothing is left over on either side.
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
            assertEquals(20, migrations.size)
            assertTrue("v17_sync" in migrations)
            assertTrue("v18_themes_and_preferences" in migrations)
            assertTrue("v19_habit_options" in migrations)
            assertTrue("v20_waiting_follow_ups" in migrations)
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
        // The sync triggers are the core's, installed once each.
        assertEquals(45L, reopened.read {
            it.long("SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'sync_outbox_%' AND type = 'trigger'")
        })
        reopened.close()
        dir.deleteRecursively()
    }

    // Rewinding a fixture database to how an older install had it. A real
    // install that lacks one migration lacks every later one too, since they
    // only ever apply in order, so each rewind takes the later ones off first.

    private fun rewindV20(connection: SQLiteConnection) {
        for (op in listOf("insert", "update", "delete")) {
            connection.execSQL("DROP TRIGGER change_log_task_metadata_$op")
            connection.execSQL("DROP TRIGGER sync_outbox_task_metadata_$op")
        }
        for (column in listOf("waitingOn", "waitingFollowUpAt", "waitingFollowUpTaskId", "followUpOfTaskId")) {
            connection.execSQL("ALTER TABLE task_metadata DROP COLUMN $column")
        }
        connection.execSQL("DELETE FROM grdb_migrations WHERE identifier = 'v20_waiting_follow_ups'")
    }

    private fun rewindV19(connection: SQLiteConnection) {
        rewindV20(connection)
        // The journal's and the outbox's dailies triggers name the new
        // columns, so they come off first.
        for (op in listOf("insert", "update", "delete")) {
            connection.execSQL("DROP TRIGGER change_log_dailies_$op")
            connection.execSQL("DROP TRIGGER sync_outbox_dailies_$op")
        }
        for (column in listOf("sourceTaskId", "placementColumn", "dropsAtDayEnd", "expiryRule", "expiresAt")) {
            connection.execSQL("ALTER TABLE dailies DROP COLUMN $column")
        }
        connection.execSQL("DELETE FROM grdb_migrations WHERE identifier = 'v19_habit_options'")
    }

    private fun rewindV18(connection: SQLiteConnection) {
        rewindV19(connection)
        for (table in listOf("themes", "preferences")) {
            for (op in listOf("insert", "update", "delete")) connection.execSQL("DROP TRIGGER sync_outbox_${table}_$op")
            connection.execSQL("DROP TABLE $table")
        }
        connection.execSQL("DELETE FROM grdb_migrations WHERE identifier = 'v18_themes_and_preferences'")
    }

    /**
     * Writes the fixture to a new file, rewinds it with [rewind], opens it
     * through the core, and checks it comes out as the fixture again, with
     * every migration recorded once.
     */
    private fun assertUpgradesToTheFixture(name: String, rewind: (SQLiteConnection) -> Unit): Unit = runBlocking {
        val expected = fixtureSchema()
        val dir = Files.createTempDirectory("priority-$name").toFile()
        val path = dir.resolve("priority.sqlite").path
        val connection = BundledSQLiteDriver().open(path)
        try {
            for (statement in SchemaFixture.splitStatements(SchemaFixture.sql())) connection.execSQL(statement)
            rewind(connection)
        } finally {
            connection.close()
        }

        val upgraded = WorkspaceDatabase.open(path)
        try {
            assertEquals(expected, upgraded.read { schema(it) })
            val migrations = upgraded.read { it.strings("SELECT identifier FROM grdb_migrations") }
            assertEquals(20, migrations.size)
            assertEquals(20, migrations.toSet().size)
        } finally {
            upgraded.close()
            dir.deleteRecursively()
        }
    }

    /** A v19 database takes the four waiting columns on `task_metadata`. */
    @Test
    fun aV19DatabaseUpgradesToTheFixture() = assertUpgradesToTheFixture("v19", ::rewindV20)

    /** A v18 database takes the habit columns, then the waiting ones. */
    @Test
    fun aV18DatabaseUpgradesToTheFixture() = assertUpgradesToTheFixture("v18", ::rewindV19)

    /** A v17 database takes themes and preferences, then v19 and v20. */
    @Test
    fun aV17DatabaseUpgradesToTheFixture() = assertUpgradesToTheFixture("v17", ::rewindV18)
}
