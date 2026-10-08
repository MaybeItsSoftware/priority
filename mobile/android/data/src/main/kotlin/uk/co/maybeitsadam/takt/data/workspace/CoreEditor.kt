package uk.co.maybeitsadam.takt.data.workspace

import uk.co.maybeitsadam.takt.core.TaskEditorMetadata
import uk.co.maybeitsadam.takt.core.TaskPlanning

// The task editor's values as the Rust core takes them (core/src/editor.rs).
// One way only: what a save leaves behind is re-read through the driver, so
// the values on screen are the ones this side decodes.

internal fun TaskPlanning.toCore() = uniffi.takt_core.Planning(
    startAtMs = startAt?.toEpochMilli(),
    dueDate = dueDate,
    requirementGroups = requirementGroups,
    minimumBlockSeconds = minimumBlockSeconds?.toLong(),
    requiresSingleSitting = requiresSingleSitting,
)

internal fun TaskEditorMetadata.toCore() = uniffi.takt_core.EditorMetadata(
    priority = priority?.toLong(),
    tags = tags,
    recurrenceRule = recurrenceRule,
    externalLinks = externalLinks,
)

internal fun TaskEditorSnapshot.toCore() = uniffi.takt_core.EditorSnapshot(
    workspaceId = workspaceId,
    taskId = taskId,
    title = title,
    notes = notes,
    dueAtMs = dueAt?.toEpochMilli(),
    estimateSeconds = estimateSeconds?.toLong(),
    metadata = metadata.toCore(),
    dailyProgress = dailyProgress,
    planning = planning?.toCore(),
)
