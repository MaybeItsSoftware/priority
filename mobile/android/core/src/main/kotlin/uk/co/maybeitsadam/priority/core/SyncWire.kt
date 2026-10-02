package uk.co.maybeitsadam.priority.core

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull

// The wire shapes from docs/sync.md, mirroring Sources/PrioritySync/SyncTransport.swift
// and the value types in WorkspaceStore+Sync.swift.

/** One SQLite value as it travels: `null`, a number or text, exactly as the column stores it. */
@Serializable(with = SyncValueSerializer::class)
sealed interface SyncValue {
    data object Null : SyncValue
    data class Integer(val value: Long) : SyncValue
    data class Real(val value: Double) : SyncValue
    data class Text(val value: String) : SyncValue
}

object SyncValueSerializer : KSerializer<SyncValue> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("SyncValue", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: SyncValue) {
        val json = encoder as JsonEncoder
        json.encodeJsonElement(
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
        val primitive = element as? JsonPrimitive ?: return SyncValue.Text(element.toString())
        if (primitive.isString) return SyncValue.Text(primitive.content)
        primitive.longOrNull?.let { return SyncValue.Integer(it) }
        primitive.doubleOrNull?.let { return SyncValue.Real(it) }
        // A JSON boolean is not something SQLite stores; carry it as 0/1.
        return when (primitive.content) {
            "true" -> SyncValue.Integer(1)
            "false" -> SyncValue.Integer(0)
            else -> SyncValue.Text(primitive.content)
        }
    }
}

@Serializable
data class SyncPushChange(
    val table: String,
    val id: String,
    /** `"upsert"` or `"delete"`. */
    val op: String,
    val hlc: String,
    val values: Map<String, SyncValue>? = null,
)

@Serializable
data class SyncPushRequest(val changes: List<SyncPushChange>)

@Serializable
data class SyncPushResponse(val accepted: Int, val cursor: Long)

/** A row as the server holds it. */
@Serializable
data class SyncIncomingRow(
    val table: String,
    val id: String,
    val deleted: Boolean,
    val values: Map<String, SyncValue> = emptyMap(),
    val hlc: String? = null,
)

@Serializable
data class SyncChangesResponse(val rows: List<SyncIncomingRow>, val cursor: Long, val hasMore: Boolean)

@Serializable
data class SyncPairRequest(
    val deviceName: String,
    val platform: String,
    val code: String? = null,
    val adminToken: String? = null,
)

@Serializable
data class SyncPairing(val deviceId: String, val token: String)

@Serializable
data class SyncPairingCode(val code: String, val expiresAt: String)

/** What a device needs to talk to the server, kept outside the database. */
@Serializable
data class SyncCredentials(val serverURL: String, val deviceId: String, val token: String)
