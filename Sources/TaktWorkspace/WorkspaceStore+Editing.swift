import Foundation
import TaktRustCore

extension WorkspaceStore {
  /// A task's editable state: the Rust core's `editor::snapshot`.
  public func taskEditorSnapshot(for taskId: String) throws -> TaskEditorSnapshot {
    TaskEditorSnapshot(try Self.mappingCoreErrors { try core.editorSnapshot(taskId: taskId) })
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
    return try taskEditorSnapshot(for: edit.taskId)
  }

  /// The folders a folder may move into: the Rust core's `records::valid_parent_folders`.
  public func validParentFolders(for folderId: String) throws -> [ListFolder] {
    try Self.mappingCoreErrors { try core.validParentFolders(folderId: folderId) }.map(ListFolder.init)
  }

  /// Saves the folder settings sheet: the Rust core's `lists::save_folder_settings`.
  public func saveFolderSettings(id: String, name: String, parentFolderId: String?, now: Date = .now) throws {
    try coreWrite { try core.saveFolderSettings(id: id, name: name, parentFolderId: parentFolderId, nowMs: now.coreMilliseconds) }
  }

  /// The root a list may show its children in place of: the Rust core's
  /// `records::visible_root_candidates`.
  public func visibleRootCandidates(in listId: String) throws -> [WorkspaceTask] {
    try Self.mappingCoreErrors { try core.visibleRootCandidates(listId: listId) }.map(WorkspaceTask.init)
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
