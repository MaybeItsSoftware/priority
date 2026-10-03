package uk.co.maybeitsadam.priority.data.db

/**
 * The workspace schema, owned by the Swift app.
 *
 * A fresh database runs `cli/src/fixtures/workspace_schema.sql` (copied into
 * this module's resources at build time), then `v17_sync` and
 * `v18_themes_and_preferences` exactly as docs/sync.md and the Swift
 * `WorkspaceStore` specify. Every step is keyed on `grdb_migrations`, so a
 * step the fixture already carries is not applied twice; an older Android
 * database takes the steps it is missing.
 */
object WorkspaceSchema {
    const val FIXTURE_RESOURCE = "uk/co/maybeitsadam/priority/data/workspace_schema.sql"
    const val V17_SYNC = "v17_sync"
    const val V18_THEMES_AND_PREFERENCES = "v18_themes_and_preferences"

    /** Tables whose rows are the user's work, keyed by column (undo journal). Same order as Swift. */
    val journalledTables: List<Pair<String, String>> = listOf(
        "task_lists" to "id",
        "list_folders" to "id",
        "tasks" to "id",
        "task_metadata" to "taskId",
        "task_conditions" to "id",
        "dailies" to "id",
        "daily_contributions" to "id",
        "kanban_boards" to "id",
    )

    /** Every synced table and its key, parents first. */
    val syncedTables: List<Pair<String, String>> = listOf(
        "workspaces" to "id",
        "list_folders" to "id",
        "task_lists" to "id",
        "tasks" to "id",
        "task_metadata" to "taskId",
        "task_conditions" to "id",
        "kanban_boards" to "id",
        "dailies" to "id",
        "daily_contributions" to "id",
        "focus_sessions" to "id",
        "focus_queue_items" to "id",
        "focus_work_blocks" to "id",
        "focus_awards" to "id",
        // `v18_themes_and_preferences`. No foreign keys, so their place is free.
        "themes" to "id",
        "preferences" to "key",
    )

    fun syncKey(table: String): String? = syncedTables.firstOrNull { it.first == table }?.second
    fun journalKey(table: String): String? = journalledTables.firstOrNull { it.first == table }?.second

    fun fixtureSQL(): String {
        val loader = WorkspaceSchema::class.java.classLoader ?: ClassLoader.getSystemClassLoader()
        val stream = loader.getResourceAsStream(FIXTURE_RESOURCE)
            ?: error("The schema fixture $FIXTURE_RESOURCE is missing from the build")
        return stream.bufferedReader().use { it.readText() }
    }

    /** Brings a database up to date. Must run inside a write transaction. */
    fun migrate(db: Db, fixture: String = fixtureSQL()) {
        if (!db.tableExists("grdb_migrations")) {
            for (statement in splitStatements(fixture)) db.execute(statement)
        }
        if (!db.exists("SELECT 1 FROM grdb_migrations WHERE identifier = ?", V17_SYNC)) {
            applyV17Sync(db)
            db.execute("INSERT INTO grdb_migrations (identifier) VALUES (?)", V17_SYNC)
        }
        if (!db.exists("SELECT 1 FROM grdb_migrations WHERE identifier = ?", V18_THEMES_AND_PREFERENCES)) {
            applyV18ThemesAndPreferences(db)
            db.execute("INSERT INTO grdb_migrations (identifier) VALUES (?)", V18_THEMES_AND_PREFERENCES)
        }
    }

    /**
     * `v18_themes_and_preferences`, as `WorkspaceStore+Themes.swift` writes it,
     * to the character, since the schema test compares SQL text. Synced, so
     * the outbox triggers are reinstalled to cover the two tables; not
     * journalled for undo.
     */
    fun applyV18ThemesAndPreferences(db: Db) {
        db.execute(
            "CREATE TABLE themes (\n" +
                "  id TEXT PRIMARY KEY,\n" +
                "  json TEXT NOT NULL,\n" +
                "  updatedAt DATETIME NOT NULL)",
        )
        db.execute(
            "CREATE TABLE preferences (\n" +
                "  key TEXT PRIMARY KEY,\n" +
                "  value TEXT,\n" +
                "  updatedAt DATETIME NOT NULL)",
        )
        installSyncTriggers(db)
    }

    /** `v17_sync`: the sync tables and the outbox triggers, as `WorkspaceStore+Sync.swift` writes them. */
    fun applyV17Sync(db: Db) {
        if (!db.tableExists("sync_control")) {
            db.execute(
                """
                CREATE TABLE sync_control (
                  id INTEGER PRIMARY KEY,
                  recording INTEGER NOT NULL DEFAULT 0,
                  applying INTEGER NOT NULL DEFAULT 0)
                """.trimIndent(),
            )
            db.execute("INSERT INTO sync_control (id) VALUES (0)")
        }
        db.execute(
            """
            CREATE TABLE IF NOT EXISTS sync_outbox (
              seq INTEGER PRIMARY KEY AUTOINCREMENT,
              tableName TEXT NOT NULL,
              rowId TEXT NOT NULL,
              operation TEXT NOT NULL,
              changedJSON TEXT,
              changedAtMs INTEGER NOT NULL)
            """.trimIndent(),
        )
        db.execute("CREATE INDEX IF NOT EXISTS sync_outbox_on_row ON sync_outbox(tableName, rowId)")
        db.execute(
            """
            CREATE TABLE IF NOT EXISTS sync_state (
              id INTEGER PRIMARY KEY,
              deviceId TEXT NOT NULL,
              cursor INTEGER NOT NULL DEFAULT 0,
              hlc TEXT,
              serverURL TEXT,
              canonicalWorkspaceId TEXT,
              needsSnapshot INTEGER NOT NULL DEFAULT 1,
              lastSyncedAt DATETIME)
            """.trimIndent(),
        )
        installSyncTriggers(db)
    }

    /**
     * The outbox triggers. Plain SQL only, so the CLI and `sqlite3` can keep
     * writing the file. They name their columns, so a migration that changes a
     * synced table's columns must reinstall them.
     */
    fun installSyncTriggers(db: Db) {
        val guardClause = """
            WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1
              AND (SELECT applying FROM sync_control WHERE id = 0) = 0
        """.trimIndent()
        val now = "CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)"
        val entry = "INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs)"
        for ((table, key) in syncedTables) {
            if (!db.tableExists(table)) continue
            val columns = db.columns(table)
            val changed = "json_array(" + columns.joinToString(", ") {
                "CASE WHEN OLD.\"$it\" IS NOT NEW.\"$it\" THEN '$it' END"
            } + ")"
            for (suffix in listOf("insert", "update", "delete")) {
                db.execute("DROP TRIGGER IF EXISTS sync_outbox_${table}_$suffix")
            }
            db.execute(
                "CREATE TRIGGER sync_outbox_${table}_insert AFTER INSERT ON $table $guardClause\n" +
                    "BEGIN $entry VALUES ('$table', NEW.\"$key\", 'insert', NULL, $now); END",
            )
            db.execute(
                "CREATE TRIGGER sync_outbox_${table}_update AFTER UPDATE ON $table $guardClause\n" +
                    "BEGIN $entry VALUES ('$table', NEW.\"$key\", 'update', $changed, $now); END",
            )
            db.execute(
                "CREATE TRIGGER sync_outbox_${table}_delete AFTER DELETE ON $table $guardClause\n" +
                    "BEGIN $entry VALUES ('$table', OLD.\"$key\", 'delete', NULL, $now); END",
            )
        }
    }

    /**
     * Splits a SQL script into statements the way `sqlite3_complete` would:
     * semicolons inside quotes, comments and trigger bodies do not end one.
     */
    fun splitStatements(script: String): List<String> {
        val statements = mutableListOf<String>()
        val current = StringBuilder()
        var quote: Char? = null
        var i = 0
        while (i < script.length) {
            val c = script[i]
            if (quote != null) {
                current.append(c)
                if (c == quote) quote = null
                i++
                continue
            }
            when {
                c == '-' && i + 1 < script.length && script[i + 1] == '-' -> {
                    while (i < script.length && script[i] != '\n') i++
                    continue
                }
                c == '\'' || c == '"' || c == '`' -> {
                    quote = c
                    current.append(c)
                }
                c == '[' -> {
                    quote = ']'
                    current.append(c)
                }
                c == ';' -> {
                    val text = current.toString().trim()
                    val isTrigger = Regex("^CREATE\\s+(TEMP\\s+|TEMPORARY\\s+)?TRIGGER", RegexOption.IGNORE_CASE)
                        .containsMatchIn(text)
                    if (isTrigger && !Regex("\\bEND$", RegexOption.IGNORE_CASE).containsMatchIn(text)) {
                        current.append(c)
                    } else {
                        if (text.isNotEmpty()) statements += text
                        current.clear()
                    }
                }
                else -> current.append(c)
            }
            i++
        }
        current.toString().trim().takeIf { it.isNotEmpty() }?.let { statements += it }
        return statements
    }
}
