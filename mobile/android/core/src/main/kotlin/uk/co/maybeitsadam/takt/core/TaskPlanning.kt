package uk.co.maybeitsadam.takt.core

import java.time.Instant

/**
 * Stored alongside metadata (`task_metadata.planningJSON`) so planning edits
 * share one undo step. References are stable condition IDs: all groups must
 * match, any member of a group may match.
 *
 * The JSON, its normalisation and the refusals' wording are the Rust core's
 * (`core/src/planning.rs`), which the Mac and iPhone wrap too.
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
        // The start is kept as given: the core only drops fields, and its
        // milliseconds would round it.
        get() = uniffi.takt_core.taskPlanningNormalized(toCore())?.let { fromCore(it).copy(startAt = startAt) }

    fun toJson(): String = uniffi.takt_core.taskPlanningEncode(toCore())

    /** The planning as the Rust core takes it. */
    fun toCore() = uniffi.takt_core.Planning(
        startAtMs = startAt?.toEpochMilli(),
        dueDate = dueDate,
        requirementGroups = requirementGroups,
        minimumBlockSeconds = minimumBlockSeconds?.toLong(),
        requiresSingleSitting = requiresSingleSitting,
    )

    companion object {
        /** Throws on malformed JSON, as Swift's `JSONDecoder` does. */
        fun fromJson(text: String): TaskPlanning = fromCore(uniffi.takt_core.taskPlanningDecode(text))

        fun fromCore(core: uniffi.takt_core.Planning) = TaskPlanning(
            startAt = core.startAtMs?.let(Instant::ofEpochMilli),
            dueDate = core.dueDate,
            requirementGroups = core.requirementGroups,
            minimumBlockSeconds = core.minimumBlockSeconds?.toInt(),
            requiresSingleSitting = core.requiresSingleSitting,
        )
    }
}

/** Why a planning edit was refused. */
enum class TaskPlanningError(private val core: uniffi.takt_core.PlanningError) {
    INVALID_CONDITION(uniffi.takt_core.PlanningError.INVALID_CONDITION),
    INVALID_SCHEDULE(uniffi.takt_core.PlanningError.INVALID_SCHEDULE),
    INVALID_MINIMUM(uniffi.takt_core.PlanningError.INVALID_MINIMUM),
    ESTIMATE_REQUIRED(uniffi.takt_core.PlanningError.ESTIMATE_REQUIRED),
    INVALID_DATE(uniffi.takt_core.PlanningError.INVALID_DATE),
    UNAVAILABLE(uniffi.takt_core.PlanningError.UNAVAILABLE),
    ;

    val message: String get() = uniffi.takt_core.taskPlanningErrorMessage(core)
}

/** Thrown form of [TaskPlanningError], for store methods that refuse an edit. */
class TaskPlanningException(val error: TaskPlanningError) : Exception(error.message)
