package uk.co.maybeitsadam.priority.data.sync

import java.time.Instant
import kotlinx.coroutines.flow.Flow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import uk.co.maybeitsadam.priority.core.SyncIncomingRow
import uk.co.maybeitsadam.priority.core.SyncValue
import uk.co.maybeitsadam.priority.data.db.Db
import uk.co.maybeitsadam.priority.data.db.WorkspaceDatabase
import uk.co.maybeitsadam.priority.data.db.WorkspaceSchema

/** What the device remembers about its sync. */
data class SyncLocalState(
    val deviceId: String,
    val cursor: Long,
    val hlc: String?,
    val serverURL: String?,
    val canonicalWorkspaceId: String?,
    val needsSnapshot: Boolean,
    val lastSyncedAt: Instant?,
    val isRecording: Boolean,
)

/** A row's local change, coalesced from its outbox entries and read from the live row. */
data class SyncOutgoingChange(
    val table: String,
    val rowId: String,
    val operation: Operation,
    /** The columns to push and their current values. Empty for a delete. */
    val values: Map<String, SyncValue>,
    /** When the newest of the coalesced edits was made, for stamping the clock. */
    val changedAtMs: Long,
) {
    enum class Operation(val wire: String) { UPSERT("upsert"), DELETE("delete") }
}

/** A batch of [SyncOutgoingChange]s and the newest outbox entry folded into it. */
data class PendingSyncChanges(val changes: List<SyncOutgoingChange>, val throughSeq: Long?)

/**
 * The store's half of sync (port of `WorkspaceStore+Sync.swift`): the outbox
 * the triggers fill, and the reads and writes [SyncEngine] drives.
 */
class SyncStore(private val database: WorkspaceDatabase) {

    /** The device's sync state, or nil while it has never been paired. */
    suspend fun syncState(): SyncLocalState? = database.read { readState(it) }

    fun observeSyncState(): Flow<SyncLocalState?> =
        database.observe(setOf("sync_state", "sync_control")) { readState(it) }

    /** How many outbox entries wait to be pushed; a write's debounce watches this. */
    fun observeOutboxSize(): Flow<Long> =
        database.observe(setOf("sync_outbox")) { it.long("SELECT COUNT(*) FROM sync_outbox") ?: 0L }

    private fun readState(db: Db): SyncLocalState? {
        val recording = (db.long("SELECT recording FROM sync_control WHERE id = 0") ?: 0L) != 0L
        return db.queryOne("SELECT * FROM sync_state WHERE id = 0") {
            SyncLocalState(
                deviceId = it.string("deviceId"),
                cursor = it.long("cursor"),
                hlc = it.stringOrNull("hlc"),
                serverURL = it.stringOrNull("serverURL"),
                canonicalWorkspaceId = it.stringOrNull("canonicalWorkspaceId"),
                needsSnapshot = it.long("needsSnapshot") != 0L,
                lastSyncedAt = it.instantOrNull("lastSyncedAt"),
                isRecording = recording,
            )
        }
    }

    /** Pairs the store with a server. The next cycle snapshots and pulls before it pushes. */
    suspend fun beginSync(deviceId: String, serverURL: String) = database.write { db ->
        db.execute(
            """
            INSERT INTO sync_state (id, deviceId, serverURL, cursor, needsSnapshot) VALUES (0, ?, ?, 0, 1)
            ON CONFLICT(id) DO UPDATE SET deviceId = excluded.deviceId, serverURL = excluded.serverURL,
              cursor = 0, needsSnapshot = 1, hlc = NULL, canonicalWorkspaceId = NULL
            """.trimIndent(),
            deviceId, serverURL,
        )
    }

    /** Unpairs: stops recording and forgets the outbox. The workspace is untouched. */
    suspend fun endSync() = database.write { db ->
        db.execute("UPDATE sync_control SET recording = 0, applying = 0 WHERE id = 0")
        db.execute("DELETE FROM sync_outbox")
        db.execute("DELETE FROM sync_state")
    }

    /** Turns recording on and queues every existing row, parents first, as an insert. */
    suspend fun enqueueSnapshot(now: Instant) = database.write { db ->
        val ms = now.toEpochMilli()
        db.execute("UPDATE sync_control SET recording = 1 WHERE id = 0")
        for ((table, key) in WorkspaceSchema.syncedTables) {
            db.execute(
                "INSERT INTO sync_outbox(tableName, rowId, operation, changedJSON, changedAtMs) " +
                    "SELECT ?, \"$key\", 'insert', NULL, ? FROM $table",
                table, ms,
            )
        }
        db.execute("UPDATE sync_state SET needsSnapshot = 0 WHERE id = 0")
    }

    /**
     * The outbox coalesced per row and read from the live rows, up to [limit]
     * rows. A row's entries are never split across two batches.
     */
    suspend fun pendingChanges(limit: Int = 500): PendingSyncChanges = database.read { db ->
        class Pending(val table: String, val rowId: String) {
            var lastOperation = ""
            var everyColumn = false
            val columns = mutableSetOf<String>()
            var changedAtMs = 0L
        }
        val pending = LinkedHashMap<String, Pending>()
        var throughSeq: Long? = null
        db.query("SELECT seq, tableName, rowId, operation, changedJSON, changedAtMs FROM sync_outbox ORDER BY seq") {
            Outbox(it.long("seq"), it.string("tableName"), it.string("rowId"), it.string("operation"),
                it.stringOrNull("changedJSON"), it.long("changedAtMs"))
        }.let { entries ->
            for (entry in entries) {
                val key = entry.table + "\u001F" + entry.rowId
                if (key !in pending) {
                    if (pending.size == limit) break
                    pending[key] = Pending(entry.table, entry.rowId)
                }
                throughSeq = entry.seq
                val item = pending.getValue(key)
                item.lastOperation = entry.operation
                item.changedAtMs = maxOf(item.changedAtMs, entry.changedAtMs)
                when (entry.operation) {
                    "insert" -> item.everyColumn = true
                    "update" -> item.columns += changedColumns(entry.changedJSON)
                }
            }
        }
        val changes = pending.values.mapNotNull { item ->
            val keyColumn = WorkspaceSchema.syncKey(item.table) ?: return@mapNotNull null
            val live = db.queryOne("SELECT * FROM ${item.table} WHERE \"$keyColumn\" = ?", item.rowId) { row ->
                row.columnNames.withIndex()
                    .filter { (_, name) -> item.everyColumn || name in item.columns || name == keyColumn }
                    .associate { (index, name) -> name to row.syncValue(index) }
            }
            if (item.lastOperation == "delete" || live == null) {
                SyncOutgoingChange(item.table, item.rowId, SyncOutgoingChange.Operation.DELETE, emptyMap(), item.changedAtMs)
            } else {
                SyncOutgoingChange(item.table, item.rowId, SyncOutgoingChange.Operation.UPSERT, live, item.changedAtMs)
            }
        }
        PendingSyncChanges(changes, throughSeq)
    }

    private data class Outbox(
        val seq: Long, val table: String, val rowId: String, val operation: String,
        val changedJSON: String?, val changedAtMs: Long,
    )

    private fun changedColumns(json: String?): List<String> {
        if (json == null) return emptyList()
        val array = runCatching { Json.parseToJsonElement(json) as? JsonArray }.getOrNull() ?: return emptyList()
        return array.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
    }

    /** Forgets the outbox entries the server has accepted. */
    suspend fun acknowledge(throughSeq: Long) = database.write { db ->
        db.execute("DELETE FROM sync_outbox WHERE seq <= ?", throughSeq)
    }

    /**
     * Writes a whole pull in one transaction with `applying = 1` and deferred
     * foreign keys, then adopts any second workspace into the canonical one,
     * clears orphans, and advances the cursor and clock. Returns whether
     * anything changed.
     */
    suspend fun applyRemoteRows(rows: List<SyncIncomingRow>, cursor: Long, hlc: String?, now: Instant): Boolean =
        database.write { db ->
            db.execute("PRAGMA defer_foreign_keys = ON")
            db.execute("UPDATE sync_control SET applying = 1 WHERE id = 0")
            var changed = false
            try {
                for (row in rows) {
                    val keyColumn = WorkspaceSchema.syncKey(row.table) ?: continue
                    // A local edit made since the push is newer than what arrived.
                    // Leave it; the next cycle pushes it and the server settles the row.
                    if (db.exists("SELECT 1 FROM sync_outbox WHERE tableName = ? AND rowId = ?", row.table, row.id)) {
                        continue
                    }
                    if (row.deleted) {
                        db.execute("DELETE FROM ${row.table} WHERE \"$keyColumn\" = ?", row.id)
                        if (db.changes() > 0) changed = true
                    } else if (upsertRemote(db, row, keyColumn)) {
                        changed = true
                    }
                }
            } finally {
                db.execute("UPDATE sync_control SET applying = 0 WHERE id = 0")
            }
            if (adoptWorkspaces(db, now)) changed = true
            if (removeOrphans(db)) changed = true
            db.execute(
                "UPDATE sync_state SET cursor = ?, hlc = COALESCE(?, hlc), lastSyncedAt = ? WHERE id = 0",
                cursor, hlc, now,
            )
            changed
        }

    /** Advances the stored clock (and optionally the cursor) without applying rows. */
    suspend fun recordProgress(cursor: Long? = null, hlc: String?, now: Instant) = database.write { db ->
        db.execute(
            "UPDATE sync_state SET cursor = COALESCE(?, cursor), hlc = COALESCE(?, hlc), lastSyncedAt = ? WHERE id = 0",
            cursor, hlc, now,
        )
    }

    /** UPDATE when the row exists, else INSERT; never INSERT OR REPLACE, whose delete would cascade. */
    private fun upsertRemote(db: Db, row: SyncIncomingRow, keyColumn: String): Boolean {
        val tableColumns = db.columns(row.table).toSet()
        val values = row.values.filter { it.key in tableColumns && it.key != keyColumn }.toSortedMap()
        val exists = db.exists("SELECT 1 FROM ${row.table} WHERE \"$keyColumn\" = ?", row.id)
        if (exists) {
            if (values.isEmpty()) return false
            db.execute(
                "UPDATE ${row.table} SET ${values.keys.joinToString(", ") { "\"$it\" = ?" }} WHERE \"$keyColumn\" = ?",
                *(values.values.toList<Any?>() + row.id).toTypedArray(),
            )
            return db.changes() > 0
        }
        val names = listOf(keyColumn) + values.keys
        val insertSQL = "INSERT INTO ${row.table} (${names.joinToString(", ") { "\"$it\"" }}) " +
            "VALUES (${names.joinToString(", ") { "?" }})"
        val arguments: Array<Any?> = (listOf<Any?>(row.id) + values.values).toTypedArray()
        // Another key may already name this row locally: two devices logged the
        // same daily on the same day, imported the same source, or made an
        // Inbox. The smaller id wins on every device; the loser goes with a
        // tombstone. An Inbox rival is the exception: the incoming Inbox wins.
        // Swift catches SQLITE_CONSTRAINT_UNIQUE; the same rival is found here
        // before inserting, because the driver's error carries no result code.
        when (val resolution = resolveUniqueRival(db, row, keyColumn, insertSQL, arguments)) {
            RivalResolution.None -> db.execute(insertSQL, *arguments)
            is RivalResolution.Removed -> {
                db.execute(insertSQL, *arguments)
                resolution.loser?.let { mergeContribution(db, into = row.id, from = it) }
            }
            RivalResolution.Inserted -> Unit
            RivalResolution.Kept -> return false
        }
        return true
    }

    private sealed interface RivalResolution {
        data object None : RivalResolution
        /** The local rival was deleted (its tombstone syncs); the incoming row takes over what it logged. */
        data class Removed(val loser: SyncIncomingRow?) : RivalResolution
        /** The incoming row is already in. */
        data object Inserted : RivalResolution
        /** The local rival won: the incoming row stays out and is tombstoned. */
        data object Kept : RivalResolution
    }

    private fun resolveUniqueRival(
        db: Db,
        row: SyncIncomingRow,
        keyColumn: String,
        insertSQL: String,
        arguments: Array<Any?>,
    ): RivalResolution {
        fun text(column: String): String? = (row.values[column] as? SyncValue.Text)?.value
        val rival = when (row.table) {
            "daily_contributions" -> db.string(
                "SELECT id FROM daily_contributions WHERE dailyId = ? AND dayKey = ?",
                text("dailyId"), text("dayKey"),
            )
            "tasks" -> db.string(
                "SELECT id FROM tasks WHERE sourceSystem IS ? AND sourceId = ?",
                text("sourceSystem"), text("sourceId"),
            )
            "task_lists" -> db.string(
                "SELECT id FROM task_lists WHERE workspaceId = ? AND systemRole = ?",
                text("workspaceId"), text("systemRole"),
            )
            else -> null
        }
        if (rival == null || rival == row.id) return RivalResolution.None
        // Recording on, so the rival's removal syncs.
        db.execute("UPDATE sync_control SET applying = 0 WHERE id = 0")
        try {
            if (row.table != "task_lists") {
                // Two devices that each made a row for the same key must pick
                // the same winner, or each deletes its own and the tombstones
                // take both. The smaller id wins everywhere.
                if (rival < row.id) {
                    db.execute(
                        "INSERT INTO sync_outbox (tableName, rowId, operation, changedJSON, changedAtMs) " +
                            "VALUES (?, ?, 'delete', NULL, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER))",
                        row.table, row.id,
                    )
                    mergeContribution(db, into = rival, from = row)
                    return RivalResolution.Kept
                }
                val loser = if (row.table == "daily_contributions") {
                    db.queryOne("SELECT secondsLogged, completedAt FROM daily_contributions WHERE id = ?", rival) {
                        val values = mutableMapOf<String, SyncValue>(
                            "secondsLogged" to SyncValue.Integer(it.long("secondsLogged")),
                        )
                        it.stringOrNull("completedAt")?.let { at -> values["completedAt"] = SyncValue.Text(at) }
                        SyncIncomingRow(row.table, rival, deleted = false, values = values)
                    }
                } else {
                    null
                }
                db.execute("DELETE FROM ${row.table} WHERE \"$keyColumn\" = ?", rival)
                return RivalResolution.Removed(loser)
            }
            // A rival Inbox keeps its tasks: they move into the incoming one,
            // which is inserted here (as a remote row) to receive them.
            db.execute("UPDATE task_lists SET systemRole = NULL WHERE id = ?", rival)
            db.execute("UPDATE sync_control SET applying = 1 WHERE id = 0")
            db.execute(insertSQL, *arguments)
            db.execute("UPDATE sync_control SET applying = 0 WHERE id = 0")
            db.execute("UPDATE tasks SET listId = ? WHERE listId = ?", row.id, rival)
            db.execute("DELETE FROM task_lists WHERE id = ?", rival)
            return RivalResolution.Inserted
        } finally {
            db.execute("UPDATE sync_control SET applying = 1 WHERE id = 0")
        }
    }

    /**
     * A day's tick on two devices keeps the most time either logged and the
     * earlier finish. Written with `applying = 0`, so the combined row syncs.
     */
    private fun mergeContribution(db: Db, into: String, from: SyncIncomingRow) {
        if (from.table != "daily_contributions") return
        val seconds = (from.values["secondsLogged"] as? SyncValue.Integer)?.value
        val completedAt = (from.values["completedAt"] as? SyncValue.Text)?.value
        db.execute("UPDATE sync_control SET applying = 0 WHERE id = 0")
        try {
            db.execute(
                """
                UPDATE daily_contributions SET
                  secondsLogged = MAX(secondsLogged, COALESCE(?, 0)),
                  completedAt = CASE WHEN completedAt IS NULL THEN ? WHEN ? IS NULL THEN completedAt
                    ELSE MIN(completedAt, ?) END
                WHERE id = ?
                  AND (secondsLogged < COALESCE(?, 0) OR (? IS NOT NULL AND (completedAt IS NULL OR completedAt > ?)))
                """.trimIndent(),
                seconds, completedAt, completedAt, completedAt, into, seconds, completedAt, completedAt,
            )
        } finally {
            db.execute("UPDATE sync_control SET applying = 1 WHERE id = 0")
        }
    }

    /**
     * Folds every workspace but the canonical one into it: the first workspace
     * this device received from the server, or its own when the server had none.
     */
    private fun adoptWorkspaces(db: Db, now: Instant): Boolean {
        val ids = db.strings("SELECT id FROM workspaces ORDER BY createdAt")
        var canonical = db.string("SELECT canonicalWorkspaceId FROM sync_state WHERE id = 0")
        if (canonical == null || canonical !in ids) {
            // Prefer a workspace the server sent: one with no outbox entry of its own.
            val remote = db.string(
                """
                SELECT id FROM workspaces
                WHERE id NOT IN (SELECT rowId FROM sync_outbox WHERE tableName = 'workspaces')
                ORDER BY createdAt LIMIT 1
                """.trimIndent(),
            )
            canonical = remote ?: ids.firstOrNull()
            db.execute("UPDATE sync_state SET canonicalWorkspaceId = ? WHERE id = 0", canonical)
        }
        if (canonical == null) return false
        val others = ids.filter { it != canonical }
        if (others.isEmpty()) return false

        val canonicalInbox = db.string(
            "SELECT id FROM task_lists WHERE workspaceId = ? AND systemRole = 'inbox'", canonical,
        )
        for (other in others) {
            val inbox = db.string("SELECT id FROM task_lists WHERE workspaceId = ? AND systemRole = 'inbox'", other)
            if (inbox != null) {
                if (canonicalInbox != null) {
                    db.execute("UPDATE tasks SET listId = ? WHERE listId = ?", canonicalInbox, inbox)
                    db.execute("DELETE FROM task_lists WHERE id = ?", inbox)
                } else {
                    db.execute("UPDATE task_lists SET workspaceId = ? WHERE id = ?", canonical, inbox)
                }
            }
            for (table in listOf("list_folders", "task_lists")) {
                db.execute("UPDATE $table SET workspaceId = ?, updatedAt = ? WHERE workspaceId = ?", canonical, now, other)
            }
            // Conditions are named, and both devices seed the same names. Keep
            // the canonical ones and drop the duplicates.
            db.execute(
                """
                DELETE FROM task_conditions WHERE workspaceId = ?
                  AND name IN (SELECT name FROM task_conditions WHERE workspaceId = ?)
                """.trimIndent(),
                other, canonical,
            )
            db.execute("UPDATE task_conditions SET workspaceId = ? WHERE workspaceId = ?", canonical, other)
            db.execute("DELETE FROM workspaces WHERE id = ?", other)
        }
        return true
    }

    /** Deletes rows whose parent was deleted elsewhere until `PRAGMA foreign_key_check` is clean. */
    private fun removeOrphans(db: Db): Boolean {
        var removedAny = false
        repeat(16) {
            val violations = db.query("PRAGMA foreign_key_check") { it.string(0) to it.long(1) }
            if (violations.isEmpty()) return removedAny
            for ((table, rowid) in violations) {
                db.execute("DELETE FROM \"$table\" WHERE rowid = ?", rowid)
                removedAny = true
            }
        }
        return removedAny
    }
}
