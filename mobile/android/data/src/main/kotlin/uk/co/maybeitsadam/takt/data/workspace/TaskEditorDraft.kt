package uk.co.maybeitsadam.takt.data.workspace

import java.time.Instant
import uk.co.maybeitsadam.takt.core.TaskEditorMetadata
import uk.co.maybeitsadam.takt.core.TaskPlanning

// The inspector's draft, with conflict detection against what was saved
// underneath it, as Sources/TaktWorkspace/TaskEditorDraft.swift keeps it. The
// estimate's reading and showing and the reconcile rule are the core's
// (`core/src/editor_draft.rs`).

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
            estimateMinutes = estimateSeconds?.let { uniffi.takt_core.editorMinutesText(it.toLong(), true) } ?: "",
            priority = metadata.priority ?: 0, tags = metadata.tags.joinToString(", "),
            recurrenceRule = metadata.recurrenceRule ?: "", links = metadata.externalLinks.joinToString("\n"),
            dailyProgress = dailyProgress, startAt = planning?.startAt, dueDate = planning?.dueDate,
            requirementGroups = planning?.requirementGroups,
            minimumBlockMinutes = planning?.minimumBlockSeconds?.let { uniffi.takt_core.editorMinutesText(it.toLong(), false) },
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
        /** Minutes as typed, to whole seconds; null when blank. The core's `editor_parse_minutes`. */
        fun parseEstimate(raw: String): Int? {
            val seconds = try {
                uniffi.takt_core.editorParseMinutes(raw)
            } catch (_: uniffi.takt_core.CoreException) {
                throw TaskEditorException(TaskEditorError.INVALID_ESTIMATE)
            } ?: return null
            if (seconds >= Int.MAX_VALUE) throw TaskEditorException(TaskEditorError.INVALID_ESTIMATE)
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
        // The comparisons are this type's; what to do with each field is the
        // core's (`editor_reconcile`), shared with the Mac and iPhone.
        val fields = TaskEditorField.entries
        val outcomes = uniffi.takt_core.editorReconcile(
            fields.map { field ->
                uniffi.takt_core.EditorFieldComparison(
                    values.matches(field, current),
                    values.matches(field, previous),
                    current.matches(field, previous),
                    field in conflicts,
                )
            },
            uniffi.takt_core.EditorEstimateCheck(
                fields.indexOf(TaskEditorField.ESTIMATE_MINUTES).toUInt(),
                values.estimateMinutes,
                current.estimateMinutes,
                baseline.estimateSeconds?.toLong(),
                saved.estimateSeconds?.toLong(),
            ),
        )
        for ((field, outcome) in fields.zip(outcomes)) {
            if (outcome.followSaved) values = values.copying(field, current)
            when (outcome.conflict) {
                true -> conflicts.add(field)
                false -> conflicts.remove(field)
                null -> Unit
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
