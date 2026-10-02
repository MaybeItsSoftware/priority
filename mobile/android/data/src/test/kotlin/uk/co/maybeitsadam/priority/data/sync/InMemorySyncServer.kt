package uk.co.maybeitsadam.priority.data.sync

import uk.co.maybeitsadam.priority.core.SyncChangesResponse
import uk.co.maybeitsadam.priority.core.SyncIncomingRow
import uk.co.maybeitsadam.priority.core.SyncPushChange
import uk.co.maybeitsadam.priority.core.SyncPushResponse
import uk.co.maybeitsadam.priority.core.SyncValue

/**
 * The server's merge rules from docs/sync.md, in memory (port of the fake in
 * sync-tests/SyncEngineTests.swift): per-column last-write-wins, a delete that
 * wins only over older edits, resurrection by a newer upsert, and a changes
 * feed that returns every row past the cursor, the caller's own included.
 */
class InMemorySyncServer {
    private class Stored {
        val data = mutableMapOf<String, SyncValue>()
        val columnClocks = mutableMapOf<String, String>()
        var deleted = false
        var deletedClock: String? = null
        var seq = 0L
        var lastDevice: String? = null
    }

    private val rows = LinkedHashMap<String, Stored>()
    private var seq = 0L

    /** How many rows the server holds, deleted ones included. */
    val rowCount: Int @Synchronized get() = rows.size

    fun transport(device: String): SyncTransport = object : SyncTransport {
        override suspend fun push(changes: List<SyncPushChange>) = push(changes, device)
        override suspend fun changes(since: Long, limit: Int, wait: Int) = changes(since, limit)
    }

    @Synchronized
    fun push(changes: List<SyncPushChange>, device: String): SyncPushResponse {
        for (change in changes) {
            val key = change.table + "/" + change.id
            val isNew = key !in rows
            val row = rows.getOrPut(key) { Stored() }
            val beforeData = row.data.toMap()
            val beforeDeleted = row.deleted
            var everyColumnWon = true
            if (change.op == "delete") {
                if (row.columnClocks.values.all { change.hlc > it }) {
                    row.deleted = true
                    row.deletedClock = change.hlc
                } else {
                    everyColumnWon = false
                }
            } else {
                val deletedClock = row.deletedClock
                if (row.deleted && deletedClock != null && change.hlc <= deletedClock) continue
                row.deleted = false
                for ((column, value) in change.values.orEmpty()) {
                    val clock = row.columnClocks[column]
                    if (clock != null && clock >= change.hlc) {
                        everyColumnWon = false
                        continue
                    }
                    row.data[column] = value
                    row.columnClocks[column] = change.hlc
                }
            }
            if (beforeData != row.data || beforeDeleted != row.deleted || isNew) {
                seq += 1
                row.seq = seq
                row.lastDevice = if (everyColumnWon) device else null
            }
        }
        return SyncPushResponse(changes.size, seq)
    }

    @Synchronized
    fun changes(since: Long, limit: Int): SyncChangesResponse {
        val newer = rows.entries.filter { it.value.seq > since }.sortedBy { it.value.seq }
        val page = newer.take(limit)
        return SyncChangesResponse(
            rows = page.map { (key, row) ->
                val (table, id) = key.split("/", limit = 2)
                SyncIncomingRow(
                    table = table,
                    id = id,
                    deleted = row.deleted,
                    values = row.data.toMap(),
                    hlc = (listOfNotNull(row.deletedClock) + row.columnClocks.values).maxOrNull(),
                )
            },
            cursor = page.lastOrNull()?.value?.seq ?: since,
            hasMore = newer.size > limit,
        )
    }
}
