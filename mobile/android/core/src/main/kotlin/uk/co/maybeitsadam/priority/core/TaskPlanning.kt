package uk.co.maybeitsadam.priority.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import java.time.Instant

/**
 * Stored alongside metadata (`task_metadata.planningJSON`) so planning edits
 * share one undo step. References are stable condition IDs: all groups must
 * match, any member of a group may match. Port of `TaskPlanning.swift`.
 *
 * JSON matches Swift's default `JSONEncoder`: absent optionals are omitted and
 * `startAt` is seconds since 2001-01-01 (`deferredToDate`).
 */
data class TaskPlanning(
    val startAt: Instant? = null,
    val dueDate: String? = null,
    val requirementGroups: List<List<String>>? = null,
    val minimumBlockSeconds: Int? = null,
    val requiresSingleSitting: Boolean? = null,
) {
    /** Empty groups and a false single-sitting flag collapse to absent; all-absent is null. */
    val normalized: TaskPlanning?
        get() {
            var result = this
            if (result.requirementGroups?.isEmpty() == true) result = result.copy(requirementGroups = null)
            if (result.requiresSingleSitting == false) result = result.copy(requiresSingleSitting = null)
            return if (result == TaskPlanning()) null else result
        }

    fun toJson(): String {
        val fields = linkedMapOf<String, kotlinx.serialization.json.JsonElement>()
        startAt?.let { fields["startAt"] = JsonPrimitive(SwiftJSON.referenceSeconds(it)) }
        dueDate?.let { fields["dueDate"] = JsonPrimitive(it) }
        requirementGroups?.let { groups ->
            fields["requirementGroups"] = JsonArray(groups.map { g -> JsonArray(g.map { JsonPrimitive(it) }) })
        }
        minimumBlockSeconds?.let { fields["minimumBlockSeconds"] = JsonPrimitive(it) }
        requiresSingleSitting?.let { fields["requiresSingleSitting"] = JsonPrimitive(it) }
        return SwiftJSON.encode(JsonObject(fields))
    }

    companion object {
        /** Throws on malformed JSON, as Swift's `JSONDecoder` does. */
        fun fromJson(text: String): TaskPlanning {
            val obj = Json.parseToJsonElement(text) as? JsonObject
                ?: throw IllegalArgumentException("TaskPlanning JSON is not an object")
            fun prim(key: String) = obj[key]?.takeUnless { it is kotlinx.serialization.json.JsonNull }?.jsonPrimitive
            return TaskPlanning(
                startAt = prim("startAt")?.let {
                    SwiftJSON.fromReferenceSeconds(it.doubleOrNull ?: throw IllegalArgumentException("startAt"))
                },
                dueDate = prim("dueDate")?.content,
                requirementGroups = obj["requirementGroups"]?.takeUnless { it is kotlinx.serialization.json.JsonNull }
                    ?.jsonArray?.map { group -> group.jsonArray.map { it.jsonPrimitive.content } },
                minimumBlockSeconds = prim("minimumBlockSeconds")?.let {
                    it.intOrNull ?: throw IllegalArgumentException("minimumBlockSeconds")
                },
                requiresSingleSitting = prim("requiresSingleSitting")?.let {
                    it.booleanOrNull ?: throw IllegalArgumentException("requiresSingleSitting")
                },
            )
        }
    }
}

/** Why a planning edit was refused. */
enum class TaskPlanningError(val message: String) {
    INVALID_CONDITION("A required condition is missing, archived or belongs to another workspace."),
    INVALID_SCHEDULE("Start must be before the deadline."),
    INVALID_MINIMUM("Enter a minimum useful block of at least one minute."),
    ESTIMATE_REQUIRED("One-sitting tasks need a positive estimate at least as long as their minimum block."),
    INVALID_DATE("Choose a valid calendar date."),
    UNAVAILABLE("This task or planned block is no longer available in the current conditions and time window."),
}

/** Thrown form of [TaskPlanningError], for store methods that refuse an edit. */
class TaskPlanningException(val error: TaskPlanningError) : Exception(error.message)

/** What Swift's default `JSONEncoder`/`JSONDecoder` would write for the types here. */
object SwiftJSON {
    /** 2001-01-01T00:00:00Z, the `Date` reference epoch. */
    val REFERENCE_DATE: Instant = Instant.parse("2001-01-01T00:00:00Z")

    fun referenceSeconds(instant: Instant): Double = secondsBetween(REFERENCE_DATE, instant)

    fun fromReferenceSeconds(seconds: Double): Instant =
        REFERENCE_DATE.plusNanos(Math.round(seconds * 1_000_000_000))

    /** Compact JSON with `/` escaped as `\/`, as `JSONEncoder` does by default. */
    fun encode(element: kotlinx.serialization.json.JsonElement): String =
        Json.encodeToString(kotlinx.serialization.json.JsonElement.serializer(), element).replace("/", "\\/")

    /** A string array, as the store writes `tagsJSON` and `externalLinksJSON`. */
    fun encodeStrings(values: List<String>): String = encode(JsonArray(values.map { JsonPrimitive(it) }))

    /** Lenient: anything that is not a JSON array of strings reads as null. */
    fun decodeStrings(text: String): List<String>? = try {
        (Json.parseToJsonElement(text) as? JsonArray)?.map { (it as JsonPrimitive).also { p -> require(p.isString) }.content }
    } catch (_: Exception) {
        null
    }
}
