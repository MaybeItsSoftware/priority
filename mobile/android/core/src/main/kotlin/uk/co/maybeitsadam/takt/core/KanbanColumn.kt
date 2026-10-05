package uk.co.maybeitsadam.takt.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.util.UUID

/**
 * A condition a task can meet to land in a rule-based board column. Port of
 * `KanbanColumnCondition` in `KanbanColumn.swift`. JSON follows Swift's
 * synthesised enum coding: `{"tag":{"_0":"work"}}`, `{"catchAll":{}}`.
 */
sealed interface KanbanColumnCondition {
    /** Task has this tag (without the `#`). */
    data class Tag(val name: String) : KanbanColumnCondition
    /** Task falls in this due bucket (`RootDueBucket.raw`). */
    data class DueBucket(val raw: Int) : KanbanColumnCondition
    /** Matches any task not already claimed by an earlier column. */
    data object CatchAll : KanbanColumnCondition
    /** Task sits in this Eisenhower quadrant (`MatrixQuadrant.raw`). */
    data class MatrixQuadrantIs(val raw: String) : KanbanColumnCondition
    /** Priority rank at or above `rank`; 1 is the top. */
    data class PriorityAtLeast(val rank: Int) : KanbanColumnCondition
    /** Task has no children. */
    data object LeafOnly : KanbanColumnCondition
    /** Task has no matrix coordinate yet. */
    data object UnplacedOnMatrix : KanbanColumnCondition

    val displayTitle: String
        get() = when (this) {
            is Tag -> "#$name"
            is DueBucket -> RootDueBucket.of(raw)?.title ?: "Due bucket $raw"
            CatchAll -> "Everything else"
            is MatrixQuadrantIs -> MatrixQuadrant.of(raw)?.title ?: "Quadrant $raw"
            is PriorityAtLeast -> "P$rank or higher"
            LeafOnly -> "Has no subtasks"
            UnplacedOnMatrix -> "Not on the matrix"
        }

    /** Whether moving a task into this condition is actionable. */
    val isWritable: Boolean
        get() = when (this) {
            is Tag -> true
            is DueBucket -> when (RootDueBucket.of(raw)) {
                RootDueBucket.TODAY, RootDueBucket.TOMORROW, RootDueBucket.NEXT_SEVEN_DAYS, RootDueBucket.NO_DUE_DATE -> true
                else -> false
            }
            CatchAll -> true
            is MatrixQuadrantIs -> true
            is PriorityAtLeast, LeafOnly, UnplacedOnMatrix -> false
        }

    fun toJson(): JsonElement = when (this) {
        is Tag -> wrap("tag", JsonPrimitive(name))
        is DueBucket -> wrap("dueBucket", JsonPrimitive(raw))
        CatchAll -> wrap("catchAll", null)
        is MatrixQuadrantIs -> wrap("matrixQuadrant", JsonPrimitive(raw))
        is PriorityAtLeast -> wrap("priorityAtLeast", JsonPrimitive(rank))
        LeafOnly -> wrap("leafOnly", null)
        UnplacedOnMatrix -> wrap("unplacedOnMatrix", null)
    }

    companion object {
        private fun wrap(key: String, value: JsonPrimitive?): JsonObject = buildJsonObject {
            put(key, if (value == null) JsonObject(emptyMap()) else JsonObject(mapOf("_0" to value)))
        }

        fun fromJson(element: JsonElement): KanbanColumnCondition? {
            val obj = element as? JsonObject ?: return null
            val (key, payload) = obj.entries.singleOrNull() ?: return null
            val value = (payload as? JsonObject)?.get("_0")?.jsonPrimitive
            return when (key) {
                "tag" -> value?.content?.let { Tag(it) }
                "dueBucket" -> value?.intOrNull?.let { DueBucket(it) }
                "catchAll" -> CatchAll
                "matrixQuadrant" -> value?.content?.let { MatrixQuadrantIs(it) }
                "priorityAtLeast" -> value?.intOrNull?.let { PriorityAtLeast(it) }
                "leafOnly" -> LeafOnly
                "unplacedOnMatrix" -> UnplacedOnMatrix
                else -> null
            }
        }
    }
}

enum class KanbanSortOrder(val raw: String, val title: String) {
    POSITION("position", "Default order"),
    DUE_ASCENDING("dueAscending", "Due date (earliest first)"),
    DUE_DESCENDING("dueDescending", "Due date (latest first)"),
    PRIORITY_ASCENDING("priorityAscending", "Priority (highest first)"),
    PRIORITY_THEN_DUE_ASCENDING("priorityThenDueAscending", "Priority, then due date"),
    ALPHABETICAL("alphabetical", "Alphabetical");

    companion object {
        fun of(raw: String): KanbanSortOrder? = entries.firstOrNull { it.raw == raw }
    }
}

/**
 * A rule-based board column. A task matches if it satisfies ANY condition;
 * columns are evaluated in order. Port of `KanbanColumn.swift`.
 */
data class KanbanColumn(
    val id: String = UUID.randomUUID().toString().uppercase(),
    val name: String,
    val conditions: List<KanbanColumnCondition>,
    val sortOrder: KanbanSortOrder = KanbanSortOrder.POSITION,
    /** Advisory card limit; null is no limit. */
    val wipLimit: Int? = null,
) {
    sealed interface Load {
        data object Unlimited : Load
        data object Within : Load
        data object AtLimit : Load
        data class Over(val by: Int) : Load
    }

    fun load(count: Int): Load {
        val limit = wipLimit
        if (limit == null || limit <= 0) return Load.Unlimited
        if (count > limit) return Load.Over(count - limit)
        if (count == limit) return Load.AtLimit
        return Load.Within
    }

    fun toJson(): JsonObject = buildJsonObject {
        put("id", id)
        put("name", name)
        put("conditions", JsonArray(conditions.map { it.toJson() }))
        put("sortOrder", sortOrder.raw)
        wipLimit?.let { put("wipLimit", it) }
    }

    companion object {
        fun fromJson(element: JsonElement): KanbanColumn {
            val obj = element.jsonObject
            return KanbanColumn(
                id = obj.getValue("id").jsonPrimitive.content,
                name = obj.getValue("name").jsonPrimitive.content,
                conditions = (obj["conditions"] as? JsonArray)?.mapNotNull { KanbanColumnCondition.fromJson(it) }
                    ?: emptyList(),
                sortOrder = KanbanSortOrder.of(obj.getValue("sortOrder").jsonPrimitive.content)
                    ?: throw IllegalArgumentException("Unknown sort order"),
                wipLimit = obj["wipLimit"]?.jsonPrimitive?.intOrNull,
            )
        }

        fun fromJson(text: String): KanbanColumn = fromJson(Json.parseToJsonElement(text))

        /** Evaluation order (specific first, catch-all last). */
        val defaults: List<KanbanColumn>
            get() = listOf(
                KanbanColumn(
                    name = "Today",
                    conditions = listOf(
                        KanbanColumnCondition.DueBucket(RootDueBucket.ASAP.raw),
                        KanbanColumnCondition.DueBucket(RootDueBucket.OVERDUE.raw),
                        KanbanColumnCondition.DueBucket(RootDueBucket.TODAY.raw),
                    ),
                    sortOrder = KanbanSortOrder.PRIORITY_THEN_DUE_ASCENDING,
                ),
                KanbanColumn(
                    name = "Next 7 Days",
                    conditions = listOf(
                        KanbanColumnCondition.DueBucket(RootDueBucket.TOMORROW.raw),
                        KanbanColumnCondition.DueBucket(RootDueBucket.NEXT_SEVEN_DAYS.raw),
                    ),
                    sortOrder = KanbanSortOrder.PRIORITY_THEN_DUE_ASCENDING,
                ),
                KanbanColumn(name = "Waiting On", conditions = listOf(KanbanColumnCondition.Tag("waiting")),
                    sortOrder = KanbanSortOrder.PRIORITY_THEN_DUE_ASCENDING),
                KanbanColumn(name = "Backlog", conditions = listOf(KanbanColumnCondition.Tag("backlog")),
                    sortOrder = KanbanSortOrder.PRIORITY_THEN_DUE_ASCENDING),
                KanbanColumn(name = "Unsorted", conditions = listOf(KanbanColumnCondition.CatchAll),
                    sortOrder = KanbanSortOrder.PRIORITY_THEN_DUE_ASCENDING),
            )
    }
}

