package uk.co.maybeitsadam.takt.data.workspace

import java.time.Instant

// A repeating task moved onto or past its own next turn — the day it would
// come round again anyway. The Rust core decides when that is
// (`tasks::recurrence_clash`); the clients ask before saving such a move, and
// "keep both" is the core's `tasks::add_occurrence_copy`. As on the Mac
// (WorkspaceStore+Editing.swift, TaskRecurrenceClash.swift).

/** A move that lands a repeating task on or past its next turn. */
data class TaskRecurrenceClash(
    val taskId: String,
    val rule: String,
    /** When the task would have come round again. */
    val nextTurn: Instant,
    /** Where it is being moved to: the due date when it has one, else the start. */
    val movedTo: Instant,
)

/** What the person can do about a clash. The same three on every client. */
enum class RecurrenceClashChoice(val title: String, val detail: String?) {
    /** Save the move as it is: one task stands for both days. The default. */
    STACK("Stack on that day", "One task stands for both days"),

    /** Save the move, then add a one-off copy at the same dates. */
    KEEP_BOTH("Keep both", "Adds a one-off copy that does not repeat"),

    /** Save nothing; the edit stays as it was so it can be changed. */
    CANCEL("Cancel", null),
    ;

    /** Whether the move is saved. */
    val saves: Boolean get() = this != CANCEL

    /** Whether a one-off copy is added after it. */
    val addsCopy: Boolean get() = this == KEEP_BOTH
}

private fun uniffi.takt_core.RecurrenceClash.toClash() = TaskRecurrenceClash(
    taskId = taskId,
    rule = rule,
    nextTurn = Instant.ofEpochMilli(nextTurnMs),
    movedTo = Instant.ofEpochMilli(movedToMs),
)

/** Whether saving [draft] moves a repeating task onto its next turn. Read-only; null for anything else. */
suspend fun WorkspaceRepository.recurrenceClash(draft: TaskEditorDraft): TaskRecurrenceClash? {
    val edit = draft.validatedSnapshot()
    return coreRead { it.editorRecurrenceClash(edit.toCore(), zone.id)?.toClash() }
}

/** The same, for a write that sets the dates directly (`scheduleTask`, `updateTask`). */
suspend fun WorkspaceRepository.recurrenceClash(taskId: String, dueAt: Instant?, startAt: Instant?): TaskRecurrenceClash? =
    coreRead { it.recurrenceClash(taskId, dueAt?.toEpochMilli(), startAt?.toEpochMilli(), zone.id)?.toClash() }

/** The clash a `scheduleTask` to [startAt] would make: the task keeps its due date. */
suspend fun WorkspaceRepository.startClash(taskId: String, startAt: Instant?): TaskRecurrenceClash? {
    val saved = taskEditorSnapshot(taskId)
    return recurrenceClash(taskId, saved.dueAt, startAt)
}

/**
 * "Keep both": a one-off copy of [taskId] beside it, carrying the dates it
 * has now — call it after the move is saved — as its own "Keep Both" step.
 * Returns the copy's id.
 */
suspend fun WorkspaceRepository.addOccurrenceCopy(taskId: String, now: Instant = Instant.now()): String {
    val edit = taskEditorSnapshot(taskId)
    return coreWrite { it.addOccurrenceCopy(edit.toCore(), now.toEpochMilli(), zone.id) }
}
