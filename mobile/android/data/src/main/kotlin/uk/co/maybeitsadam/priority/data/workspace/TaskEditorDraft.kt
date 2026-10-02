package uk.co.maybeitsadam.priority.data.workspace

import java.time.Instant
import uk.co.maybeitsadam.priority.core.TaskEditorMetadata
import uk.co.maybeitsadam.priority.core.TaskPlanning

// Port of Sources/PriorityWorkspace/TaskEditorDraft.swift: the inspector's
// draft, with conflict detection against what was saved underneath it.

enum class TaskEditorField(val label: String) {
    TITLE("Title"),
    NOTES("Notes"),
    DUE_AT("Due date"),
    ESTIMATE_MINUTES("Estimate"),
    PRIORITY("Priority"),
    TAGS("Tags"),
    RECURRENCE_RULE("Repeat"),
    LINKS("Links"),
    DAILY_PROGRESS("Daily progress"),
    START_AT("Start"),
    DUE_DATE("Due day"),
    REQUIREMENTS("Conditions"),
    MINIMUM_BLOCK("Minimum block"),
    SINGLE_SITTING("One sitting"),
}

class TaskEditorException(val error: TaskEditorError) : Exception(error.message)

enum class TaskEditorError(val message: String) {
    INVALID_ESTIMATE("Enter a non-negative number of minutes within the supported range."),
    INVALID_PRIORITY("Choose a priority between None and Urgent."),
    CONFLICTING_CHANGES("Saved values have changed. Review the conflicting fields before saving."),
    INVALID_VISIBLE_ROOT("Choose the list's only imported top-level task, with children, as its visible root."),
}

/** Only editable values take part in conflict detection. */
data class TaskEditorSnapshot(
    val workspaceId: String,
    val taskId: String,
    val title: String,
    val notes: String,
    val dueAt: Instant?,
    val estimateSeconds: Int?,
    val metadata: TaskEditorMetadata,
    val dailyProgress: Boolean,
    val planning: TaskPlanning? = null,
) {
    val values: TaskEditorValues
        get() = TaskEditorValues(
            title = title, notes = notes, dueAt = dueAt,
            estimateMinutes = estimateSeconds?.let { if (it % 60 == 0) (it / 60).toString() else swiftDouble(it / 60.0) }
                ?: "",
            priority = metadata.priority ?: 0, tags = metadata.tags.joinToString(", "),
            recurrenceRule = metadata.recurrenceRule ?: "", links = metadata.externalLinks.joinToString("\n"),
            dailyProgress = dailyProgress, startAt = planning?.startAt, dueDate = planning?.dueDate,
            requirementGroups = planning?.requirementGroups,
            minimumBlockMinutes = planning?.minimumBlockSeconds?.let { swiftDouble(it / 60.0) },
            requiresSingleSitting = planning?.requiresSingleSitting,
        )
}

/** Raw text stays intact until Save, including temporarily invalid input. */
data class TaskEditorValues(
    val title: String,
    val notes: String,
    val dueAt: Instant?,
    val estimateMinutes: String,
    val priority: Int,
    val tags: String,
    val recurrenceRule: String,
    val links: String,
    val dailyProgress: Boolean,
    val startAt: Instant? = null,
    val dueDate: String? = null,
    val requirementGroups: List<List<String>>? = null,
    val minimumBlockMinutes: String? = null,
    val requiresSingleSitting: Boolean? = null,
) {
    fun matches(field: TaskEditorField, other: TaskEditorValues): Boolean = when (field) {
        TaskEditorField.TITLE -> title == other.title
        TaskEditorField.NOTES -> notes == other.notes
        TaskEditorField.DUE_AT -> dueAt == other.dueAt
        TaskEditorField.ESTIMATE_MINUTES -> estimateMinutes == other.estimateMinutes
        TaskEditorField.PRIORITY -> priority == other.priority
        TaskEditorField.TAGS -> tags == other.tags
        TaskEditorField.RECURRENCE_RULE -> recurrenceRule == other.recurrenceRule
        TaskEditorField.LINKS -> links == other.links
        TaskEditorField.DAILY_PROGRESS -> dailyProgress == other.dailyProgress
        TaskEditorField.START_AT -> startAt == other.startAt
        TaskEditorField.DUE_DATE -> dueDate == other.dueDate
        TaskEditorField.REQUIREMENTS -> requirementGroups == other.requirementGroups
        TaskEditorField.MINIMUM_BLOCK -> minimumBlockMinutes == other.minimumBlockMinutes
        TaskEditorField.SINGLE_SITTING -> requiresSingleSitting == other.requiresSingleSitting
    }

    fun copying(field: TaskEditorField, other: TaskEditorValues): TaskEditorValues = when (field) {
        TaskEditorField.TITLE -> copy(title = other.title)
        TaskEditorField.NOTES -> copy(notes = other.notes)
        TaskEditorField.DUE_AT -> copy(dueAt = other.dueAt)
        TaskEditorField.ESTIMATE_MINUTES -> copy(estimateMinutes = other.estimateMinutes)
        TaskEditorField.PRIORITY -> copy(priority = other.priority)
        TaskEditorField.TAGS -> copy(tags = other.tags)
        TaskEditorField.RECURRENCE_RULE -> copy(recurrenceRule = other.recurrenceRule)
        TaskEditorField.LINKS -> copy(links = other.links)
        TaskEditorField.DAILY_PROGRESS -> copy(dailyProgress = other.dailyProgress)
        TaskEditorField.START_AT -> copy(startAt = other.startAt)
        TaskEditorField.DUE_DATE -> copy(dueDate = other.dueDate)
        TaskEditorField.REQUIREMENTS -> copy(requirementGroups = other.requirementGroups)
        TaskEditorField.MINIMUM_BLOCK -> copy(minimumBlockMinutes = other.minimumBlockMinutes)
        TaskEditorField.SINGLE_SITTING -> copy(requiresSingleSitting = other.requiresSingleSitting)
    }

    companion object {
        private val estimatePattern = Regex("^(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)$")

        /** Minutes as typed, to whole seconds; nil when blank. */
        fun parseEstimate(raw: String): Int? {
            val value = raw.trimmedWhitespace()
            if (value.isEmpty()) return null
            val minutes = value.takeIf { estimatePattern.matches(it) }?.toDoubleOrNull()
            if (minutes == null || !minutes.isFinite() || minutes < 0) {
                throw TaskEditorException(TaskEditorError.INVALID_ESTIMATE)
            }
            val seconds = Math.rint(minutes * 60)
            if (!seconds.isFinite() || seconds >= Int.MAX_VALUE.toDouble()) {
                throw TaskEditorException(TaskEditorError.INVALID_ESTIMATE)
            }
            return seconds.toInt()
        }
    }
}

/** An editing session over one task: the saved baseline, the typed values, and any conflicts. */
data class TaskEditorDraft(
    val baseline: TaskEditorSnapshot,
    val values: TaskEditorValues = baseline.values,
    val conflicts: Set<TaskEditorField> = emptySet(),
    val isUnavailable: Boolean = false,
) {
    val isDirty: Boolean get() = values != baseline.values || conflicts.isNotEmpty()

    /** Folds a newly saved snapshot in: untouched fields follow it, edited ones that diverge conflict. */
    fun reconciled(saved: TaskEditorSnapshot): TaskEditorDraft {
        if (saved.workspaceId != baseline.workspaceId || saved.taskId != baseline.taskId) return this
        val previous = baseline.values
        val current = saved.values
        var values = this.values
        val conflicts = this.conflicts.toMutableSet()
        for (field in TaskEditorField.entries) {
            if (values.matches(field, current)) {
                conflicts.remove(field)
            } else if (!values.matches(field, previous) || field in conflicts) {
                if (!current.matches(field, previous)) conflicts.add(field)
            } else {
                values = values.copying(field, current)
            }
            if (field == TaskEditorField.ESTIMATE_MINUTES && !values.matches(field, previous) &&
                saved.estimateSeconds != baseline.estimateSeconds
            ) {
                val parsed = runCatching { TaskEditorValues.parseEstimate(values.estimateMinutes) }
                val parsedValue = parsed.getOrNull()
                val converged = parsed.isSuccess && parsedValue == saved.estimateSeconds &&
                    (values.estimateMinutes.trimmedWhitespace().isEmpty() || parsedValue != null)
                if (converged) conflicts.remove(field) else conflicts.add(field)
            }
        }
        return copy(baseline = saved, values = values, conflicts = conflicts, isUnavailable = false)
    }

    fun resolved(field: TaskEditorField, useSaved: Boolean): TaskEditorDraft = copy(
        values = if (useSaved) values.copying(field, baseline.values) else values,
        conflicts = conflicts - field,
    )

    fun validatedSnapshot(): TaskEditorSnapshot {
        if (isUnavailable) fail(WorkspaceStoreError.MISSING_TASK)
        if (conflicts.isNotEmpty()) throw TaskEditorException(TaskEditorError.CONFLICTING_CHANGES)
        var result = baseline.copy(title = nonEmptyName(values.title), notes = values.notes, dueAt = values.dueAt)
        if (values.estimateMinutes != baseline.values.estimateMinutes) {
            result = result.copy(estimateSeconds = TaskEditorValues.parseEstimate(values.estimateMinutes))
        }
        if (values.priority !in 0..4) throw TaskEditorException(TaskEditorError.INVALID_PRIORITY)
        var metadata = result.metadata.copy(priority = if (values.priority == 0) null else values.priority)
        if (values.tags != baseline.values.tags) {
            metadata = metadata.copy(tags = normalizedStrings(values.tags.split(",")))
        }
        if (values.recurrenceRule != baseline.values.recurrenceRule) {
            metadata = metadata.copy(recurrenceRule = values.recurrenceRule.trimmedWhitespace().ifEmpty { null })
        }
        if (values.links != baseline.values.links) {
            metadata = metadata.copy(externalLinks = normalizedStrings(values.links.split(Regex("\\R"))))
        }
        val minimum = if (values.minimumBlockMinutes != baseline.values.minimumBlockMinutes) {
            TaskEditorValues.parseEstimate(values.minimumBlockMinutes ?: "")
        } else {
            baseline.planning?.minimumBlockSeconds
        }
        result = result.copy(
            metadata = metadata,
            dailyProgress = values.dailyProgress,
            planning = TaskPlanning(
                startAt = values.startAt, dueDate = values.dueDate, requirementGroups = values.requirementGroups,
                minimumBlockSeconds = minimum, requiresSingleSitting = values.requiresSingleSitting,
            ).normalized,
        )
        if (values.dueDate != null) result = result.copy(dueAt = null)
        return result
    }
}

/** `String(Double)` as Swift prints it: `1.5`, `2.0`, `0.25`. */
internal fun swiftDouble(value: Double): String {
    if (value == Math.floor(value) && !value.isInfinite() && Math.abs(value) < 1e16) return "${value.toLong()}.0"
    return value.toString()
}
