package uk.co.maybeitsadam.takt.data.workspace

import uk.co.maybeitsadam.takt.core.TaskEditorMetadata
import uk.co.maybeitsadam.takt.core.TaskPlanning

// The task editor's values as the Rust core takes them (core/src/editor.rs).
// One way only: what a save leaves behind is re-read through the driver, so
// the values on screen are the ones this side decodes.

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

internal fun uniffi.takt_core.EditorSnapshot.toSnapshot() = TaskEditorSnapshot(
    workspaceId = workspaceId,
    taskId = taskId,
    title = title,
    notes = notes,
    dueAt = dueAtMs?.let(java.time.Instant::ofEpochMilli),
    estimateSeconds = estimateSeconds?.toInt(),
    metadata = TaskEditorMetadata(
        priority = metadata.priority?.toInt(),
        tags = metadata.tags,
        recurrenceRule = metadata.recurrenceRule,
        externalLinks = metadata.externalLinks,
    ),
    dailyProgress = dailyProgress,
    planning = planning?.let(TaskPlanning::fromCore),
)

internal fun uk.co.maybeitsadam.takt.core.FocusContext.toCore() = uniffi.takt_core.FocusContext(
    conditionIds = conditionIDs.sorted(),
    endsAtMs = endsAt?.toEpochMilli(),
    mode = mode.raw,
)
