import Foundation
import GRDB

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

  @discardableResult
  public func saveTaskEditor(_ draft: TaskEditorDraft, now: Date = .now) throws -> TaskEditorSnapshot {
    let edit = try draft.validatedSnapshot()
    return try journalledWrite("Edit Task") { db in
      let current = try Self.taskEditorSnapshot(db, taskId: edit.taskId)
      guard current == draft.baseline else { throw TaskEditorError.conflictingChanges }
      try Self.updatePlanning(db, edit: edit, previous: current.planning, previousDueAt: current.dueAt, now: now)
      try Self.updateTaskRecord(db, edit: edit, now: now)
      try Self.updateEditorMetadata(db, taskId: edit.taskId, metadata: edit.metadata, now: now)
      try Self.setDailyAttachment(db, taskId: edit.taskId, enabled: edit.dailyProgress,
                                  estimateSeconds: edit.estimateSeconds, now: now)
      return try Self.taskEditorSnapshot(db, taskId: edit.taskId)
    }
  }

  static func updateTaskRecord(_ db: Database, edit: TaskEditorSnapshot, now: Date) throws {
    guard var task = try WorkspaceTask.fetchOne(db, key: edit.taskId) else { throw WorkspaceStoreError.missingTask }
    guard task.title != edit.title || task.notes != edit.notes || task.dueAt != edit.dueAt
      || task.estimateSeconds != edit.estimateSeconds else { return }
    task.title = edit.title
    task.notes = edit.notes
    task.dueAt = edit.dueAt
    task.estimateSeconds = edit.estimateSeconds
    task.updatedAt = now
    try task.update(db)
  }

  static func updateEditorMetadata(_ db: Database, taskId: String, metadata: TaskEditorMetadata, now: Date) throws {
    guard try WorkspaceTask.fetchOne(db, key: taskId) != nil else { throw WorkspaceStoreError.missingTask }
    let tags = normalizedStrings(metadata.tags)
    let links = normalizedStrings(metadata.externalLinks)
    let recurrence = metadata.recurrenceRule?.trimmingCharacters(in: .whitespacesAndNewlines)
    let priority = metadata.priority.flatMap { (1...4).contains($0) ? $0 : nil }
    let existing = try TaskMetadata.fetchOne(db, key: taskId)
    var record = existing ?? TaskMetadata(
      taskId: taskId, priority: nil, startAt: nil, tagsJSON: "[]", recurrenceRule: nil,
      matrixUrgency: nil, matrixImportance: nil, kanbanColumn: nil, externalLinksJSON: "[]", updatedAt: now)
    let newRecurrence = recurrence?.isEmpty == true ? nil : recurrence
    guard record.priority != priority || decodeStringArray(record.tagsJSON) != tags
      || record.recurrenceRule != newRecurrence || decodeStringArray(record.externalLinksJSON) != links else { return }
    record.priority = priority
    record.tagsJSON = String(data: try JSONEncoder().encode(tags), encoding: .utf8) ?? "[]"
    record.recurrenceRule = newRecurrence
    record.externalLinksJSON = String(data: try JSONEncoder().encode(links), encoding: .utf8) ?? "[]"
    record.updatedAt = now
    if existing == nil { try record.insert(db) } else { try record.update(db) }
  }

  static func setDailyAttachment(
    _ db: Database, taskId: String, enabled: Bool, estimateSeconds: Int?, now: Date
  ) throws {
    let existing = try WorkspaceDaily.filter(Column("taskId") == taskId).fetchOne(db)
    let isEnabled = existing.map { $0.archivedAt == nil } ?? false
    guard isEnabled != enabled else { return }
    if enabled {
      _ = try Self.makeDailyRecord(db, taskId: taskId, targetSeconds: estimateSeconds, now: now)
    } else {
      try Self.archiveDailyRecord(db, taskId: taskId, now: now)
    }
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

  public func saveFolderSettings(id: String, name: String, parentFolderId: String?, now: Date = .now) throws {
    let name = try Self.nonEmptyName(name)
    try journalledWrite("Edit Folder") { db in
      guard var folder = try ListFolder.fetchOne(db, key: id) else { throw WorkspaceStoreError.missingFolder }
      try Self.validateFolderParent(db, folder: folder, parentFolderId: parentFolderId)
      guard folder.name != name || folder.parentFolderId != parentFolderId else { return }
      if folder.parentFolderId != parentFolderId {
        folder.sortOrder = try Self.nextOrder(
          db, table: ListFolder.databaseTableName, whereSQL: "workspaceId = ? AND parentFolderId IS ?",
          arguments: [folder.workspaceId, parentFolderId])
      }
      folder.name = name
      folder.parentFolderId = parentFolderId
      folder.updatedAt = now
      try folder.update(db)
    }
  }

  static func validateFolderParent(_ db: Database, folder: ListFolder, parentFolderId: String?) throws {
    guard parentFolderId != folder.id else { throw WorkspaceStoreError.invalidFolderMove }
    if let parentFolderId {
      guard let parent = try ListFolder.fetchOne(db, key: parentFolderId), parent.workspaceId == folder.workspaceId else {
        throw WorkspaceStoreError.missingFolder
      }
      guard try !Self.folderDescendantIDs(db, of: folder.id).contains(parentFolderId) else {
        throw WorkspaceStoreError.invalidFolderMove
      }
    }
  }

  public func visibleRootCandidates(in listId: String) throws -> [WorkspaceTask] {
    try database.read { db in
      let roots = try WorkspaceTask.filter(Column("listId") == listId && Column("parentTaskId") == nil).fetchAll(db)
      guard roots.count == 1, let root = roots.first, root.sourceSystem != nil || root.isList,
        try (root.isList || WorkspaceTask.filter(Column("parentTaskId") == root.id).fetchCount(db) > 0) else { return [] }
      return [root]
    }
  }

  static func validateVisibleRoot(_ db: Database, listId: String, rootId: String?) throws {
    guard let rootId else { return }
    let roots = try WorkspaceTask.filter(Column("listId") == listId && Column("parentTaskId") == nil).fetchAll(db)
    guard roots.count == 1, let root = roots.first, root.id == rootId, root.sourceSystem != nil || root.isList,
      try (root.isList || WorkspaceTask.filter(Column("parentTaskId") == rootId).fetchCount(db) > 0) else {
      throw TaskEditorError.invalidVisibleRoot
    }
  }

  public func saveListSettings(
    id: String, name: String, colorHex: String?, folderId: String?, isArchived: Bool,
    visibleRootTaskId: String?, now: Date = .now
  ) throws {
    let name = try Self.nonEmptyName(name)
    let color = colorHex?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedColor = color?.isEmpty == true ? nil : color
    try journalledWrite("Edit List") { db in
      guard var list = try TaskList.fetchOne(db, key: id) else { throw WorkspaceStoreError.missingList }
      if let folderId {
        guard let folder = try ListFolder.fetchOne(db, key: folderId), folder.workspaceId == list.workspaceId else {
          throw WorkspaceStoreError.missingFolder
        }
      }
      if isArchived, list.isSystemList { throw WorkspaceStoreError.systemListIsPermanent }
      // Retaining an existing identity is allowed even if the wrapper moved;
      // changing it explicitly must validate the proposed visible hierarchy.
      if list.visibleRootTaskId != visibleRootTaskId {
        try Self.validateVisibleRoot(db, listId: id, rootId: visibleRootTaskId)
      }
      guard list.name != name || list.colorHex != normalizedColor || list.folderId != folderId
        || list.isArchived != isArchived || list.visibleRootTaskId != visibleRootTaskId else { return }
      if list.folderId != folderId {
        list.sortOrder = try Self.nextOrder(
          db, table: TaskList.databaseTableName, whereSQL: "workspaceId = ? AND folderId IS ?",
          arguments: [list.workspaceId, folderId])
      }
      list.name = name
      list.colorHex = normalizedColor
      list.folderId = folderId
      list.isArchived = isArchived
      list.visibleRootTaskId = visibleRootTaskId
      list.updatedAt = now
      try list.update(db)
    }
  }
}
