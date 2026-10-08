import Foundation
import TaktRustCore

/// Bringing work in from somewhere else. Split from `WorkspaceStore.swift` —
/// the same type — because importing is a distinct job from editing, with its
/// own rule: running it twice must not produce two copies of anything.
extension WorkspaceStore {
  /// Copies tasks from an outside service into the workspace, and can be run
  /// again safely.
  ///
  /// A seed whose `(sourceSystem, sourceId)` is already present updates the
  /// task that is there rather than adding a second copy — and updates only
  /// its *content*. Where the task sits locally, which list it was moved to,
  /// and what it was reordered under are the user's decisions about their own
  /// workspace, so a re-import leaves them alone.
  ///
  /// Broken source parent links become roots instead of losing the task, and
  /// duplicate source IDs within one run are rejected.
  @discardableResult
  public func importTasks(
    workspaceId: String,
    listName: String,
    sourceSystem: String,
    seeds: [ImportedTaskSeed],
    now: Date = .now
  ) throws -> TaskImportOutcome? {
    // The Rust core's `imports::import_tasks`.
    let core = seeds.map { seed in
      TaktRustCore.ImportedTaskSeed(
        sourceId: seed.sourceId, parentSourceId: seed.parentSourceId, title: seed.title, notes: seed.notes,
        status: seed.status.rawValue, sortOrder: Int64(seed.sortOrder))
    }
    guard let outcome = try coreWrite({
      try self.core.importTasks(
        workspaceId: workspaceId, listName: listName, sourceSystem: sourceSystem, seeds: core,
        nowMs: now.coreMilliseconds)
    }) else { return nil }
    guard let list = try Self.mappingCoreErrors({ try self.core.list(id: outcome.listId) }).map(TaskList.init) else {
      throw WorkspaceStoreError.missingList
    }
    return TaskImportOutcome(
      list: list, insertedTaskIDs: outcome.insertedTaskIds, updatedTaskIDs: outcome.updatedTaskIds,
      createdList: outcome.createdList)
  }
}
