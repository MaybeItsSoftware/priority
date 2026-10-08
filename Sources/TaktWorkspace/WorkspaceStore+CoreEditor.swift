import Foundation
import TaktRustCore

// The task editor's values as the Rust core takes them (core/src/editor.rs).
// One way only: what comes back from a save is re-read through GRDB, so the
// dates on screen are the ones GRDB decodes and comparisons stay exact.

extension TaskPlanning {
  var core: Planning {
    Planning(
      startAtMs: startAt?.coreMilliseconds, dueDate: dueDate, requirementGroups: requirementGroups,
      minimumBlockSeconds: minimumBlockSeconds.map { Int64($0) }, requiresSingleSitting: requiresSingleSitting)
  }
}

extension TaskEditorMetadata {
  var core: EditorMetadata {
    EditorMetadata(
      priority: priority.map { Int64($0) }, tags: tags, recurrenceRule: recurrenceRule,
      externalLinks: externalLinks)
  }
}

extension TaskEditorSnapshot {
  var core: EditorSnapshot {
    EditorSnapshot(
      workspaceId: workspaceId, taskId: taskId, title: title, notes: notes,
      dueAtMs: dueAt?.coreMilliseconds, estimateSeconds: estimateSeconds.map { Int64($0) },
      metadata: metadata.core, dailyProgress: dailyProgress, planning: planning?.core)
  }
}
