package uk.co.maybeitsadam.takt.data.workspace

import uk.co.maybeitsadam.takt.core.TaskCondition
import uniffi.takt_core.ConditionSection

/** Conditions under one heading: a category, or "Other" for the uncategorised. */
data class ConditionGroup(
    /** The category, or null for the uncategorised. */
    val category: String?,
    /** What the heading says. */
    val title: String,
    /** Whether saying one holds replaces the rest: the Location heading. */
    val isExclusive: Boolean,
    val conditions: List<TaskCondition>,
)

/**
 * The headings conditions are shown under and what "Where you are" offers.
 * The rules are the Rust core's (`core/src/conditions.rs`), so the phones and
 * the Mac group alike.
 */
object ConditionGroups {
    /** The category places are filed under. */
    const val LOCATION = "Location"

    /** Every condition under its heading: Location first, the rest alphabetically, then "Other". */
    fun all(conditions: List<TaskCondition>): List<ConditionGroup> =
        uniffi.takt_core.conditionSections(conditions.map { it.toRow() }).toGroups(conditions)

    /**
     * What "Where you are" offers: only the conditions an open task requires,
     * plus any that is on so it can be turned off. Empty when nothing needs one.
     */
    fun available(conditions: List<TaskCondition>, required: Set<String>, active: Set<String>): List<ConditionGroup> =
        uniffi.takt_core.availableConditionSections(
            conditions.map { it.toRow() }, required.toList(), active.toList(),
        ).toGroups(conditions)

    /** The categories a condition can be filed under: Location, then every other one in use. */
    fun categories(conditions: List<TaskCondition>): List<String> =
        uniffi.takt_core.conditionCategories(conditions.map { it.toRow() })

    private fun List<ConditionSection>.toGroups(conditions: List<TaskCondition>): List<ConditionGroup> {
        val byId = conditions.associateBy { it.id }
        return map { section ->
            ConditionGroup(
                category = section.category,
                title = section.title,
                isExclusive = section.isExclusive,
                conditions = section.conditions.mapNotNull { byId[it.id] },
            )
        }
    }
}
