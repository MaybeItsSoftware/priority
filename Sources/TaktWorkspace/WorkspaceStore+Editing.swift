import Foundation
import GRDB
import TaktRustCore

extension WorkspaceStore {
  public func taskEditorSnapshot(for taskId: String) throws -> TaskEditorSnapshot {
    try database.read { try Self.taskEditorSnapshot($0, taskId: taskId) }
  }

  static func taskEditorSnapshot(_ db: Database, taskId: String) throws -> TaskEditorSnapshot {
    guard let task = try WorkspaceTask.fetchOne(db, key: taskId),
      let list = try TaskList.fetchOne(db, key: task.listId) else { throw WorkspaceStoreError.missingTask }
    let record = try TaskMetadata.fetchOne(db, key: taskId)
    let metadata = record.map {
      TaskEditorMetadata(priority: $0.priority, tags: decodeStringArray($0.tagsJSON),
                         recurrenceRule: $0.recurrenceRule, externalLinks: decodeStringArray($0.externalLinksJSON))
    } ?? TaskEditorMetadata()
    let daily = try WorkspaceDaily.filter(Column("taskId") == taskId && Column("archivedAt") == nil).fetchOne(db)
    var snapshot = TaskEditorSnapshot(
      workspaceId: list.workspaceId, taskId: taskId, title: task.title, notes: task.notes,
      dueAt: task.dueAt, estimateSeconds: task.estimateSeconds, metadata: metadata, dailyProgress: daily != nil)
    snapshot.planning = try planning(record)
    return snapshot
  }

  /// Saves the editor as one step, refusing if the task changed since the
  /// draft's baseline was read: the Rust core's `editor::save_editor`.
  @discardableResult
  public func saveTaskEditor(_ draft: TaskEditorDraft, now: Date = .now) throws -> TaskEditorSnapshot {
    let edit = try draft.validatedSnapshot()
    try coreWrite {
      _ = try core.saveEditor(
        edit: edit.core, baseline: draft.baseline.core, nowMs: now.coreMilliseconds, zone: TimeZone.current.identifier)
    }
    return try database.read { db in try Self.taskEditorSnapshot(db, taskId: edit.taskId) }
  }

  public func validParentFolders(for folderId: String) throws -> [ListFolder] {
    try database.read { db in
      guard let folder = try ListFolder.fetchOne(db, key: folderId) else { throw WorkspaceStoreError.missingFolder }
      let excluded = try Self.folderDescendantIDs(db, of: folderId).union([folderId])
      return try ListFolder.filter(Column("workspaceId") == folder.workspaceId)
        .order(Column("sortOrder"), Column("createdAt"), Column("id")).fetchAll(db)
        .filter { !excluded.contains($0.id) }
    }
  }

  /// Saves the folder settings sheet: the Rust core's `lists::save_folder_settings`.
  public func saveFolderSettings(id: String, name: String, parentFolderId: String?, now: Date = .now) throws {
    try coreWrite { try core.saveFolderSettings(id: id, name: name, parentFolderId: parentFolderId, nowMs: now.coreMilliseconds) }
  }

  public func visibleRootCandidates(in listId: String) throws -> [WorkspaceTask] {
    try database.read { db in
      let roots = try WorkspaceTask.filter(Column("listId") == listId && Column("parentTaskId") == nil).fetchAll(db)
      guard roots.count == 1, let root = roots.first, root.sourceSystem != nil || root.isList,
        try (root.isList || WorkspaceTask.filter(Column("parentTaskId") == root.id).fetchCount(db) > 0) else { return [] }
      return [root]
    }
  }

  /// Saves the list settings sheet: the Rust core's `lists::save_list_settings`.
  public func saveListSettings(
    id: String, name: String, colorHex: String?, folderId: String?, isArchived: Bool,
    visibleRootTaskId: String?, now: Date = .now
  ) throws {
    let settings = ListSettings(
      name: name, colourHex: colorHex, folderId: folderId, isArchived: isArchived,
      visibleRootTaskId: visibleRootTaskId)
    try coreWrite { try core.saveListSettings(id: id, settings: settings, nowMs: now.coreMilliseconds) }
  }
}
