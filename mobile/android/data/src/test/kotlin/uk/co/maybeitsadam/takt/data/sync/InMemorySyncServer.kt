package uk.co.maybeitsadam.takt.data.sync

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import uk.co.maybeitsadam.takt.core.SyncValue

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
        // The bodies are the core's; the server reads and writes them as JSON,
        // as the real one does, so the test holds the core to the wire format.
        override suspend fun push(body: String) {
            push(wireJson.decodeFromString<WirePush>(body).changes, device)
        }

        override suspend fun changes(since: Long, limit: Int, wait: Int): String =
            wireJson.encodeToString(changes(since, limit))
    }

    @Synchronized
    fun push(changes: List<WireChange>, device: String): WirePushResponse {
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
        return WirePushResponse(changes.size, seq)
    }

    @Synchronized
    fun changes(since: Long, limit: Int): WirePage {
        val newer = rows.entries.filter { it.value.seq > since }.sortedBy { it.value.seq }
        val page = newer.take(limit)
        return WirePage(
            rows = page.map { (key, row) ->
                val (table, id) = key.split("/", limit = 2)
                WireRow(
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

// The wire shapes from docs/sync.md, for the test server only: the app leaves
// the bodies to the core.
internal val wireJson = Json { ignoreUnknownKeys = true; explicitNulls = false }

@Serializable
data class WirePush(val changes: List<WireChange>)

@Serializable
data class WireChange(
    val table: String,
    val id: String,
    val op: String,
    val hlc: String,
    val values: Map<String, @Serializable(with = WireValueSerializer::class) SyncValue>? = null,
)

@Serializable
data class WirePushResponse(val accepted: Int, val cursor: Long)

@Serializable
data class WireRow(
    val table: String,
    val id: String,
    val deleted: Boolean,
    val values: Map<String, @Serializable(with = WireValueSerializer::class) SyncValue> = emptyMap(),
    val hlc: String? = null,
)

@Serializable
data class WirePage(val rows: List<WireRow>, val cursor: Long, val hasMore: Boolean)

object WireValueSerializer : KSerializer<SyncValue> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("SyncValue", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: SyncValue) {
        (encoder as JsonEncoder).encodeJsonElement(
            when (value) {
                SyncValue.Null -> JsonNull
                is SyncValue.Integer -> JsonPrimitive(value.value)
                is SyncValue.Real -> JsonPrimitive(value.value)
                is SyncValue.Text -> JsonPrimitive(value.value)
            },
        )
    }

    override fun deserialize(decoder: Decoder): SyncValue {
        val element = (decoder as JsonDecoder).decodeJsonElement()
        if (element is JsonNull) return SyncValue.Null
        val primitive = element as JsonPrimitive
        if (primitive.isString) return SyncValue.Text(primitive.content)
        primitive.longOrNull?.let { return SyncValue.Integer(it) }
        return SyncValue.Real(primitive.doubleOrNull ?: 0.0)
    }
}
