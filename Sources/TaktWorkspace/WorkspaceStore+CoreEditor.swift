import Foundation
import TaktCore
import TaktRustCore

// The task editor's values as the Rust core takes them (core/src/editor.rs).
// Both ways: the snapshot the editor opens with is the core's too, so a
// baseline and the row it guards carry dates rounded the same way.

extension TaskPlanning {
  var core: Planning {
    Planning(
      startAtMs: startAt?.coreMilliseconds, dueDate: dueDate, requirementGroups: requirementGroups,
      minimumBlockSeconds: minimumBlockSeconds.map { Int64($0) }, requiresSingleSitting: requiresSingleSitting)
  }
}

extension TaskPlanning {
  init(_ core: Planning) {
    self.init(
      startAt: core.startAtMs.map(Date.init(coreMilliseconds:)), dueDate: core.dueDate,
      requirementGroups: core.requirementGroups, minimumBlockSeconds: core.minimumBlockSeconds.map { Int($0) },
      requiresSingleSitting: core.requiresSingleSitting)
  }
}

extension TaskEditorMetadata {
  init(_ core: EditorMetadata) {
    self.init(
      priority: core.priority.map { Int($0) }, tags: core.tags, recurrenceRule: core.recurrenceRule,
      externalLinks: core.externalLinks)
  }

  var core: EditorMetadata {
    EditorMetadata(
      priority: priority.map { Int64($0) }, tags: tags, recurrenceRule: recurrenceRule,
      externalLinks: externalLinks)
  }
}

extension TaskEditorSnapshot {
  init(_ core: EditorSnapshot) {
    self.init(
      workspaceId: core.workspaceId, taskId: core.taskId, title: core.title, notes: core.notes,
      dueAt: core.dueAtMs.map(Date.init(coreMilliseconds:)), estimateSeconds: core.estimateSeconds.map { Int($0) },
      metadata: TaskEditorMetadata(core.metadata), dailyProgress: core.dailyProgress)
    planning = core.planning.map(TaskPlanning.init)
  }

  var core: EditorSnapshot {
    EditorSnapshot(
      workspaceId: workspaceId, taskId: taskId, title: title, notes: notes,
      dueAtMs: dueAt?.coreMilliseconds, estimateSeconds: estimateSeconds.map { Int64($0) },
      metadata: metadata.core, dailyProgress: dailyProgress, planning: planning?.core)
  }
}

extension TaktCore.FocusContext {
  var core: TaktRustCore.FocusContext {
    TaktRustCore.FocusContext(
      conditionIds: conditionIDs.sorted(), endsAtMs: endsAt?.coreMilliseconds, mode: mode.rawValue)
  }
}
