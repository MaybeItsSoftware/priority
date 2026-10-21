package uk.co.maybeitsadam.takt.core

/**
 * One member of a requirement group, read: the condition it names, and
 * whether it asks for that condition *not* to hold (`!home`, shown as "not
 * Home"). The reading is the Rust core's (`core/src/conditions/requirement.rs`),
 * as on the Mac and iPhone (`TaskRequirement` in TaktCore), so every client
 * and the ranking agree on what `!` means.
 */
data class TaskRequirement(val conditionId: String, val isNegated: Boolean) {
    /** The member as stored. */
    val member: String get() = uniffi.takt_core.requirementMember(conditionId, isNegated)

    /** Whether it is met while [available] hold. */
    fun isMet(available: Set<String>): Boolean = isMet(listOf(member), available)

    /** "Home", or "not Home". */
    fun label(name: String): String = if (isNegated) "not $name" else name

    companion object {
        /** A member as stored. */
        fun parse(member: String) = TaskRequirement(
            uniffi.takt_core.requirementConditionId(member),
            uniffi.takt_core.requirementIsNegated(member),
        )

        /** A member written out: its condition's name, "not " before it when negated. */
        fun label(member: String, name: (String) -> String): String =
            parse(member).let { it.label(name(it.conditionId)) }

        /** A group written out: "Campus or not Quiet". */
        fun label(group: List<String>, name: (String) -> String): String =
            group.joinToString(" or ") { label(it, name) }

        /** Whether any member of [group] is met while [available] hold. */
        fun isMet(group: List<String>, available: Set<String>): Boolean =
            uniffi.takt_core.requirementGroupIsMet(group, available.toList())
    }
}
