import Foundation
import GRDB
import PriorityCore

/// The local source of truth for Priority's desktop workspace.
///
/// It intentionally has no knowledge of Checkvist or app UI. External services
/// translate their data into local records at the edge, so normal task editing
/// never needs network access.
public final class WorkspaceStore: @unchecked Sendable {
  /// Internal rather than private so the extensions in the sibling files —
  /// the same type, split only for size — can reach it.
  let database: DatabasePool

  public convenience init() throws {
    try self.init(databaseURL: WorkspaceStore.defaultDatabaseURL())
  }

  public init(databaseURL: URL) throws {
    let directory = databaseURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
    }
    self.database = try DatabasePool(path: databaseURL.path, configuration: configuration)
    try Self.migrator.migrate(database)
  }

  public static func defaultDatabaseURL() -> URL {
    // The file keeps the product's old name: it is the one thing every other
    // reader (the CLI, `scripts/dump_workspace_schema.sh`) finds by name, and
    // renaming it would buy nothing a user can see.
    AppIdentity.applicationSupportDirectory()
      .appending(path: "priority.sqlite", directoryHint: .notDirectory)
  }

  @discardableResult
  public func bootstrapIfNeeded(now: Date = .now) throws -> Workspace {
    if let workspace = try database.read({ db in try Workspace.fetchOne(db) }) {
      // A workspace whose inbox was deleted before the role existed would
      // otherwise have nowhere for quick capture to land.
      try database.write { db in try Self.ensureInbox(db, workspaceId: workspace.id, now: now) }
      return workspace
    }

    let workspace = Workspace(id: UUID().uuidString, name: "My Workspace", createdAt: now, updatedAt: now)
    try database.write { db in
      try workspace.insert(db)
      try Self.ensureInbox(db, workspaceId: workspace.id, now: now)
      try Self.seedConditions(db, workspaceId: workspace.id, now: now)
    }
    return workspace
  }

  /// The list quick capture lands in. Never archived, never deleted, and found
  /// by its role rather than by its name.
  public func inbox(in workspaceId: String) throws -> TaskList? {
    try database.read { db in try Self.inbox(db, workspaceId: workspaceId) }
  }

  private static func inbox(_ db: Database, workspaceId: String) throws -> TaskList? {
    try TaskList
      .filter(Column("workspaceId") == workspaceId && Column("systemRole") == TaskListRole.inbox.rawValue)
      .fetchOne(db)
  }

  @discardableResult
  private static func ensureInbox(_ db: Database, workspaceId: String, now: Date) throws -> TaskList {
    if var existing = try inbox(db, workspaceId: workspaceId) {
      // Archiving is blocked, but a database from before the role existed can
      // still arrive with the inbox out of sight.
      if existing.isArchived {
        existing.isArchived = false
        existing.updatedAt = now
        try existing.update(db)
      }
      return existing
    }
    let order = try nextOrder(
      db, table: TaskList.databaseTableName, whereSQL: "workspaceId = ? AND folderId IS ?",
      arguments: [workspaceId, nil])
    let inbox = TaskList(
      id: UUID().uuidString, workspaceId: workspaceId, folderId: nil, name: "Inbox",
      colorHex: nil, sortOrder: order, isArchived: false, systemRole: .inbox,
      createdAt: now, updatedAt: now)
    try inbox.insert(db)
    return inbox
  }

  public func workspaces() throws -> [Workspace] {
    try database.read { db in
      try Workspace.order(Column("createdAt")).fetchAll(db)
    }
  }

  public func folders(in workspaceId: String) throws -> [ListFolder] {
    try database.read { db in
      try ListFolder.filter(Column("workspaceId") == workspaceId)
        .order(Column("sortOrder"), Column("createdAt"), Column("id")).fetchAll(db)
    }
  }

  public func lists(in workspaceId: String, includingArchived: Bool = false) throws -> [TaskList] {
    try database.read { db in
      var request = TaskList.filter(Column("workspaceId") == workspaceId)
      if !includingArchived { request = request.filter(Column("isArchived") == false) }
      return try request.order(Column("sortOrder"), Column("createdAt"), Column("id")).fetchAll(db)
    }
  }

  public func createFolder(
    workspaceId: String,
    name: String,
    parentFolderId: String? = nil,
    now: Date = .now
  ) throws -> ListFolder {
    let trimmed = try Self.nonEmptyName(name)
    return try journalledWrite("New Folder") { db in
      if let parentFolderId {
        guard let folder = try ListFolder.fetchOne(db, key: parentFolderId), folder.workspaceId == workspaceId else {
          throw WorkspaceStoreError.missingFolder
        }
      }
      let nextOrder = try Self.nextOrder(
        db, table: ListFolder.databaseTableName, whereSQL: "workspaceId = ? AND parentFolderId IS ?",
        arguments: [workspaceId, parentFolderId])
      let folder = ListFolder(
        id: UUID().uuidString, workspaceId: workspaceId, parentFolderId: parentFolderId,
        name: trimmed, sortOrder: nextOrder, createdAt: now, updatedAt: now)
      try folder.insert(db)
      return folder
    }
  }

  public func createList(
    workspaceId: String,
    name: String,
    folderId: String? = nil,
    now: Date = .now
  ) throws -> TaskList {
    let trimmed = try Self.nonEmptyName(name)
    return try journalledWrite("New List") { db in
      if let folderId {
        guard let folder = try ListFolder.fetchOne(db, key: folderId), folder.workspaceId == workspaceId else {
          throw WorkspaceStoreError.missingFolder
        }
      }
      let nextOrder = try Self.nextOrder(
        db, table: TaskList.databaseTableName, whereSQL: "workspaceId = ? AND folderId IS ?",
        arguments: [workspaceId, folderId])
      let list = TaskList(
        id: UUID().uuidString, workspaceId: workspaceId, folderId: folderId, name: trimmed,
        colorHex: nil, sortOrder: nextOrder, isArchived: false, createdAt: now, updatedAt: now)
      try list.insert(db)
      return list
    }
  }

  public func task(id: String) throws -> WorkspaceTask? {
    try database.read { db in try WorkspaceTask.fetchOne(db, key: id) }
  }

  public func updateFolder(id: String, name: String, now: Date = .now) throws {
    let trimmed = try Self.nonEmptyName(name)
    try journalledWrite("Rename Folder") { db in
      guard var folder = try ListFolder.fetchOne(db, key: id) else { throw WorkspaceStoreError.missingFolder }
      guard folder.name != trimmed else { return }
      folder.name = trimmed
      folder.updatedAt = now
      try folder.update(db)
    }
  }

  public func moveFolder(id: String, toParentFolderId parentFolderId: String?, now: Date = .now) throws {
    try journalledWrite("Move Folder") { db in
      guard var folder = try ListFolder.fetchOne(db, key: id) else { throw WorkspaceStoreError.missingFolder }
      try Self.validateFolderParent(db, folder: folder, parentFolderId: parentFolderId)
      guard folder.parentFolderId != parentFolderId else { return }
      folder.parentFolderId = parentFolderId
      folder.sortOrder = try Self.nextOrder(
        db, table: ListFolder.databaseTableName, whereSQL: "workspaceId = ? AND parentFolderId IS ?",
        arguments: [folder.workspaceId, parentFolderId])
      folder.updatedAt = now
      try folder.update(db)
    }
  }

  public func deleteFolder(id: String) throws {
    try journalledWrite("Delete Folder") { db in
      guard try ListFolder.fetchOne(db, key: id) != nil else { throw WorkspaceStoreError.missingFolder }
      // Lists are intentionally retained: the schema's SET NULL relation moves
      // them to the sidebar root. Child folders cascade with their parent.
      try ListFolder.deleteOne(db, key: id)
    }
  }

  public func updateList(id: String, name: String, colorHex: String?, now: Date = .now) throws {
    let trimmed = try Self.nonEmptyName(name)
    let color = colorHex?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    try journalledWrite("Edit List") { db in
      guard var list = try TaskList.fetchOne(db, key: id) else { throw WorkspaceStoreError.missingList }
      guard list.name != trimmed || list.colorHex != color else { return }
      list.name = trimmed
      list.colorHex = color
      list.updatedAt = now
      try list.update(db)
    }
  }

  /// Renames a list and touches nothing else.
  ///
  /// Separate from `updateList` so that renaming from the sidebar cannot carry
  /// a stale colour along with it, and so undo offers "Rename List" rather
  /// than the settings sheet's broader "Edit List".
  public func renameList(id: String, name: String, now: Date = .now) throws {
    let trimmed = try Self.nonEmptyName(name)
    try journalledWrite("Rename List") { db in
      guard var list = try TaskList.fetchOne(db, key: id) else { throw WorkspaceStoreError.missingList }
      guard list.name != trimmed else { return }
      list.name = trimmed
      list.updatedAt = now
      try list.update(db)
    }
  }

  public func moveList(id: String, toFolderId folderId: String?, now: Date = .now) throws {
    try journalledWrite("Move List") { db in
      guard var list = try TaskList.fetchOne(db, key: id) else { throw WorkspaceStoreError.missingList }
      if let folderId {
        guard let folder = try ListFolder.fetchOne(db, key: folderId), folder.workspaceId == list.workspaceId else {
          throw WorkspaceStoreError.missingFolder
        }
      }
      guard list.folderId != folderId else { return }
      list.folderId = folderId
      list.sortOrder = try Self.nextOrder(
        db, table: TaskList.databaseTableName, whereSQL: "workspaceId = ? AND folderId IS ?",
        arguments: [list.workspaceId, folderId])
      list.updatedAt = now
      try list.update(db)
    }
  }

  public func moveListWithinFolder(id: String, by offset: Int, now: Date = .now) throws {
    try journalledWrite("Reorder List") { db in
      guard let list = try TaskList.fetchOne(db, key: id) else { throw WorkspaceStoreError.missingList }
      var siblings = try TaskList
        .filter(Column("workspaceId") == list.workspaceId && Column("folderId") == list.folderId)
        .filter(Column("isArchived") == list.isArchived)
        .order(Column("sortOrder"), Column("createdAt"), Column("id")).fetchAll(db)
      guard let index = siblings.firstIndex(where: { $0.id == id }) else { return }
      let target = min(max(0, index + offset), siblings.count - 1)
      guard target != index else { return }
      siblings.insert(siblings.remove(at: index), at: target)
      try Self.persistListOrder(siblings, db: db, now: now)
    }
  }

  /// Puts `id` immediately before `targetID` among its siblings, moving it
  /// into `folderId` first when the drag crossed a folder boundary.
  ///
  /// `targetID` of nil means the end of that group, which is what a drop below
  /// the last row means. Reordering is absolute rather than a signed offset
  /// because a drag says where a thing landed, not how far it travelled.
  public func placeList(
    id: String, before targetID: String?, inFolderId folderId: String?, now: Date = .now
  ) throws {
    try journalledWrite("Reorder List") { db in
      guard var list = try TaskList.fetchOne(db, key: id) else { throw WorkspaceStoreError.missingList }
      guard id != targetID else { return }
      if let folderId {
        guard let folder = try ListFolder.fetchOne(db, key: folderId), folder.workspaceId == list.workspaceId else {
          throw WorkspaceStoreError.missingFolder
        }
      }
      if list.folderId != folderId {
        list.folderId = folderId
        list.updatedAt = now
        try list.update(db)
      }
      var siblings = try TaskList
        .filter(Column("workspaceId") == list.workspaceId && Column("folderId") == folderId)
        .filter(Column("isArchived") == list.isArchived)
        .order(Column("sortOrder"), Column("createdAt"), Column("id")).fetchAll(db)
      guard let index = siblings.firstIndex(where: { $0.id == id }) else { return }
      let moved = siblings.remove(at: index)
      let target = targetID.flatMap { id in siblings.firstIndex { $0.id == id } } ?? siblings.count
      siblings.insert(moved, at: target)
      try Self.persistListOrder(siblings, db: db, now: now)
    }
  }

  /// The same placement for folders, which nest, so the parent is checked for
  /// the cycle a folder dropped inside its own descendant would make.
  public func placeFolder(
    id: String, before targetID: String?, inParentFolderId parentFolderId: String?, now: Date = .now
  ) throws {
    try journalledWrite("Reorder Folder") { db in
      guard var folder = try ListFolder.fetchOne(db, key: id) else { throw WorkspaceStoreError.missingFolder }
      guard id != targetID else { return }
      if let parentFolderId {
        guard let parent = try ListFolder.fetchOne(db, key: parentFolderId),
          parent.workspaceId == folder.workspaceId else {
          throw WorkspaceStoreError.missingFolder
        }
        // Walking up from the intended parent must not arrive back at the
        // folder being moved, or the tree stops being a tree.
        var ancestorID: String? = parentFolderId
        var visited: Set<String> = []
        while let current = ancestorID, visited.insert(current).inserted {
          if current == id { throw WorkspaceStoreError.invalidFolderMove }
          ancestorID = try ListFolder.fetchOne(db, key: current)?.parentFolderId
        }
      }
      if folder.parentFolderId != parentFolderId {
        folder.parentFolderId = parentFolderId
        folder.updatedAt = now
        try folder.update(db)
      }
      var siblings = try ListFolder
        .filter(Column("workspaceId") == folder.workspaceId && Column("parentFolderId") == parentFolderId)
        .order(Column("sortOrder"), Column("createdAt"), Column("id")).fetchAll(db)
      guard let index = siblings.firstIndex(where: { $0.id == id }) else { return }
      let moved = siblings.remove(at: index)
      let target = targetID.flatMap { id in siblings.firstIndex { $0.id == id } } ?? siblings.count
      siblings.insert(moved, at: target)
      try Self.persistFolderOrder(siblings, db: db, now: now)
    }
  }

  public func moveFolderWithinSiblings(id: String, by offset: Int, now: Date = .now) throws {
    try journalledWrite("Reorder Folder") { db in
      guard let folder = try ListFolder.fetchOne(db, key: id) else { throw WorkspaceStoreError.missingFolder }
      var siblings = try ListFolder
        .filter(Column("workspaceId") == folder.workspaceId && Column("parentFolderId") == folder.parentFolderId)
        .order(Column("sortOrder"), Column("createdAt"), Column("id")).fetchAll(db)
      guard let index = siblings.firstIndex(where: { $0.id == id }) else { return }
      let target = min(max(0, index + offset), siblings.count - 1)
      guard target != index else { return }
      siblings.insert(siblings.remove(at: index), at: target)
      try Self.persistFolderOrder(siblings, db: db, now: now)
    }
  }

  public func setListArchived(_ archived: Bool, id: String, now: Date = .now) throws {
    try journalledWrite("Archive List") { db in
      guard var list = try TaskList.fetchOne(db, key: id) else { throw WorkspaceStoreError.missingList }
      // A system list is somewhere the app puts things by itself, so it has to
      // be somewhere the user can still see.
      if archived, list.isSystemList { throw WorkspaceStoreError.systemListIsPermanent }
      list.isArchived = archived
      list.updatedAt = now
      try list.update(db)
    }
  }

  public func deleteList(id: String) throws {
    try journalledWrite("Delete List") { db in
      guard let list = try TaskList.fetchOne(db, key: id) else { throw WorkspaceStoreError.missingList }
      guard !list.isSystemList else { throw WorkspaceStoreError.systemListIsPermanent }
      try TaskList.deleteOne(db, key: id)
    }
  }

  public func outline(in listId: String, parentTaskId: String? = nil) throws -> [TaskOutlineItem] {
    try listTree(in: listId).outline(under: parentTaskId)
  }

  /// The direct children used by a project's own Kanban board. Descendants are
  /// intentionally excluded: each project can be entered and planned as its
  /// own board without inheriting its parent's column.
  public func tasks(in listId: String, parentTaskId: String? = nil) throws -> [WorkspaceTask] {
    try database.read { db in
      try WorkspaceTask
        .filter(Column("listId") == listId && Column("parentTaskId") == parentTaskId)
        .order(Column("sortOrder"), Column("createdAt"))
        .fetchAll(db)
    }
  }

  /// Returns the imported wrapper by its persisted identity. If it has been
  /// moved or promoted alongside other roots, show the actual hierarchy.
  public func visibleRootParentTaskID(for list: TaskList) throws -> String? {
    try database.read { db in
      try Self.visibleRootParentTaskID(db, listId: list.id)
    }
  }

  private static func visibleRootParentTaskID(_ db: Database, listId: String) throws -> String? {
    guard let list = try TaskList.fetchOne(db, key: listId), let rootID = list.visibleRootTaskId else { return nil }
    let roots = try WorkspaceTask
      .filter(Column("listId") == listId && Column("parentTaskId") == nil).fetchAll(db)
    guard roots.count == 1, roots.first?.id == rootID else { return nil }
    return rootID
  }

  /// Recognise wrappers once, at import or migration, rather than during edits.
  static func registerVisibleRoot(_ db: Database, for list: TaskList) throws {
    let roots = try WorkspaceTask
      .filter(Column("listId") == list.id && Column("parentTaskId") == nil).fetchAll(db)
    let listName = normalizedVisibleRootName(list.name)
    guard roots.count == 1, let root = roots.first, root.sourceSystem != nil,
      !listName.isEmpty, normalizedVisibleRootName(root.title) == listName,
      try WorkspaceTask.filter(Column("parentTaskId") == root.id).fetchCount(db) > 0
    else { return }
    var updated = list
    updated.visibleRootTaskId = root.id
    try updated.update(db)
  }

  /// The virtual Everything scope aggregates active lists without changing
  /// any task's real list or parent.
  public func visibleRootTasks(in workspaceId: String) throws -> [WorkspaceTask] {
    try lists(in: workspaceId).flatMap { list in
      let parentID = try visibleRootParentTaskID(for: list)
      return try tasks(in: list.id, parentTaskId: parentID)
    }
  }

  private static func normalizedVisibleRootName(_ name: String) -> String {
    name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: "", options: .regularExpression)
  }

  public func createTask(
    listId: String,
    title: String,
    parentTaskId: String? = nil,
    kind: WorkspaceItemKind = .task,
    kanbanColumn: String? = nil,
    startAt: Date? = nil,
    atTop: Bool = false,
    adjacentTaskId: String? = nil,
    above: Bool = false,
    dueAt: Date? = nil,
    estimateSeconds: Int? = nil,
    tags: [String] = [],
    priority: Int? = nil,
    now: Date = .now
  ) throws -> WorkspaceTask {
    let trimmed = try Self.nonEmptyName(title)
    // What the add field read off the end of the title, written in the same
    // undo step as the task: undoing a typed task should not leave its
    // estimate behind as a second step to undo first.
    let tags = Self.normalizedStrings(tags)
    let priority = priority.flatMap { (1...4).contains($0) ? $0 : nil }
    let estimateSeconds = estimateSeconds.flatMap { $0 > 0 ? $0 : nil }
    return try journalledWrite("New Task") { db in
      guard try TaskList.fetchOne(db, key: listId) != nil else { throw WorkspaceStoreError.missingList }
      if let parentTaskId {
        guard let parent = try WorkspaceTask.fetchOne(db, key: parentTaskId), parent.listId == listId else {
          throw WorkspaceStoreError.invalidTaskMove
        }
      }
      let nextOrder = try Self.nextOrder(
        db, table: WorkspaceTask.databaseTableName, whereSQL: "listId = ? AND parentTaskId IS ?",
        arguments: [listId, parentTaskId])
      let task = WorkspaceTask(
        id: UUID().uuidString, listId: listId, parentTaskId: parentTaskId, title: trimmed,
        notes: "", status: .open, sortOrder: nextOrder, dueAt: dueAt, estimateSeconds: estimateSeconds,
        itemKind: kind, createdAt: now, updatedAt: now)
      try task.insert(db)
      if kanbanColumn != nil || startAt != nil || !tags.isEmpty || priority != nil {
        let tagsJSON = String(data: try JSONEncoder().encode(tags), encoding: .utf8) ?? "[]"
        try db.execute(sql: """
          INSERT INTO task_metadata(taskId, priority, startAt, tagsJSON, externalLinksJSON, kanbanColumn, updatedAt)
          VALUES (?, ?, ?, ?, '[]', ?, ?)
          """, arguments: [task.id, priority, startAt, tagsJSON, kanbanColumn, now])
      }
      if atTop || adjacentTaskId != nil {
        var siblings = try WorkspaceTask
          .filter(Column("listId") == listId && Column("parentTaskId") == parentTaskId)
          .order(Column("sortOrder"), Column("createdAt"), Column("id")).fetchAll(db)
        siblings.removeAll { $0.id == task.id }
        let insertion: Int
        if let adjacentTaskId {
          guard let index = siblings.firstIndex(where: { $0.id == adjacentTaskId }) else {
            throw WorkspaceStoreError.invalidTaskMove
          }
          insertion = index + (above ? 0 : 1)
        } else { insertion = 0 }
        siblings.insert(task, at: insertion)
        try Self.persistTaskOrder(siblings, db: db, now: now)
      }
      return try WorkspaceTask.fetchOne(db, key: task.id) ?? task
    }
  }

  public func setStatus(_ status: TaskStatus, for taskId: String, now: Date = .now) throws {
    try journalledWrite("Change Status") { db in
      guard var task = try WorkspaceTask.fetchOne(db, key: taskId) else { return }
      task.status = status
      // Only stamp a task that is newly closed. Re-closing an already closed
      // task — which a sync or a repeated command can do — would otherwise
      // move it into today and inflate the count.
      let wasOpen = task.completedAt == nil
      task.completedAt = status == .open ? nil : (task.completedAt ?? now)
      task.updatedAt = now
      try task.update(db)
      // Closing one occurrence of a repeating task writes the next one.
      if status != .open, wasOpen {
        try Self.scheduleNextOccurrence(db, after: task, now: now)
      }
    }
  }

  public func updateTask(
    id: String,
    title: String,
    notes: String,
    dueAt: Date?,
    estimateSeconds: Int?,
    now: Date = .now
  ) throws {
    let trimmed = try Self.nonEmptyName(title)
    try journalledWrite("Edit Task") { db in
      var edit = try Self.taskEditorSnapshot(db, taskId: id)
      let previous = edit
      edit.title = trimmed
      edit.notes = notes
      edit.dueAt = dueAt
      edit.estimateSeconds = estimateSeconds
      if dueAt != nil { edit.planning?.dueDate = nil; edit.planning = edit.planning?.normalized }
      try Self.updatePlanning(db, edit: edit, previous: previous.planning, previousDueAt: previous.dueAt, now: now)
      try Self.updateTaskRecord(db, edit: edit, now: now)
    }
  }

  public func taskEditorMetadata(for taskId: String) throws -> TaskEditorMetadata {
    try database.read { db in try Self.taskEditorSnapshot(db, taskId: taskId).metadata }
  }

  public func updateTaskEditorMetadata(
    taskId: String, metadata: TaskEditorMetadata, now: Date = .now
  ) throws {
    try journalledWrite("Edit Task Details") { db in
      try Self.updateEditorMetadata(db, taskId: taskId, metadata: metadata, now: now)
    }
  }

  public func kanbanColumn(for taskId: String) throws -> String? {
    try database.read { db in try TaskMetadata.fetchOne(db, key: taskId)?.kanbanColumn }
  }

  /// Loads board placement in batches rather than opening a read per card.
  /// Missing metadata retains the same unplaced/default-column behaviour.
  public func boardMetadata(for taskIDs: [String]) throws -> (
    columns: [String: String], positions: [String: TaskMatrixPosition]
  ) {
    guard !taskIDs.isEmpty else { return ([:], [:]) }
    return try database.read { db in
      var columns: [String: String] = [:]
      var positions = Dictionary(uniqueKeysWithValues: Set(taskIDs).map {
        ($0, TaskMatrixPosition(urgency: nil, importance: nil))
      })
      // Stay below SQLite's parameter limit even for large imported trees.
      for start in stride(from: 0, to: taskIDs.count, by: 500) {
        let ids = Array(taskIDs[start..<min(start + 500, taskIDs.count)])
        for record in try TaskMetadata.filter(ids.contains(Column("taskId"))).fetchAll(db) {
          columns[record.taskId] = record.kanbanColumn
          positions[record.taskId] = TaskMatrixPosition(
            urgency: record.matrixUrgency, importance: record.matrixImportance)
        }
      }
      return (columns, positions)
    }
  }

  public func setKanbanColumn(_ column: String?, for taskId: String, now: Date = .now) throws {
    try setKanbanColumn(column, for: [taskId], now: now)
  }

  /// Moving a whole column is one transaction and one undo step.
  public func setKanbanColumn(_ column: String?, for taskIDs: [String], now: Date = .now) throws {
    let ids = Array(Set(taskIDs))
    guard !ids.isEmpty else { return }
    let value = column?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    try journalledWrite("Move Task") { db in
      for start in stride(from: 0, to: ids.count, by: 500) {
        let batch = Array(ids[start..<min(start + 500, ids.count)])
        let count = try WorkspaceTask.filter(batch.contains(Column("id"))).fetchCount(db)
        guard count == batch.count else { throw WorkspaceStoreError.missingTask }
      }
      for id in ids {
        try db.execute(sql: """
          INSERT INTO task_metadata(taskId, tagsJSON, externalLinksJSON, kanbanColumn, updatedAt)
          VALUES (?, '[]', '[]', ?, ?)
          ON CONFLICT(taskId) DO UPDATE SET
            kanbanColumn = excluded.kanbanColumn, updatedAt = excluded.updatedAt
          """, arguments: [id, value, now])
      }
    }
  }

  public func matrixPosition(for taskId: String) throws -> TaskMatrixPosition {
    try database.read { db in
      let metadata = try TaskMetadata.fetchOne(db, key: taskId)
      return TaskMatrixPosition(urgency: metadata?.matrixUrgency, importance: metadata?.matrixImportance)
    }
  }

  public func setMatrixPosition(
    _ position: TaskMatrixPosition,
    for taskId: String,
    now: Date = .now
  ) throws {
    try journalledWrite("Move Task") { db in
      guard try WorkspaceTask.fetchOne(db, key: taskId) != nil else { throw WorkspaceStoreError.missingTask }
      var record = try TaskMetadata.fetchOne(db, key: taskId) ?? TaskMetadata(
        taskId: taskId, priority: nil, startAt: nil, tagsJSON: "[]", recurrenceRule: nil,
        matrixUrgency: nil, matrixImportance: nil, kanbanColumn: nil, externalLinksJSON: "[]", updatedAt: now)
      record.matrixUrgency = position.urgency
      record.matrixImportance = position.importance
      record.updatedAt = now
      if try TaskMetadata.fetchOne(db, key: taskId) == nil {
        try record.insert(db)
      } else {
        try record.update(db)
      }
    }
  }

  /// Moves a task and its complete subtree. A destination parent must belong to
  /// the destination list and may not be the task itself or one of its descendants.
  public func moveTask(
    id: String, toListId listId: String, parentTaskId: String? = nil,
    toVisibleRoot: Bool = false, now: Date = .now
  ) throws {
    try journalledWrite("Move Task") { db in
      guard var task = try WorkspaceTask.fetchOne(db, key: id) else { throw WorkspaceStoreError.missingTask }
      guard try TaskList.fetchOne(db, key: listId) != nil else { throw WorkspaceStoreError.missingList }
      let parentTaskId = toVisibleRoot ? try Self.visibleRootParentTaskID(db, listId: listId) : parentTaskId
      let descendants = try Self.taskDescendantIDs(db, of: id)
      guard parentTaskId != id, parentTaskId.map({ !descendants.contains($0) }) ?? true else {
        throw WorkspaceStoreError.invalidTaskMove
      }
      if let parentTaskId {
        guard let parent = try WorkspaceTask.fetchOne(db, key: parentTaskId), parent.listId == listId else {
          throw WorkspaceStoreError.invalidTaskMove
        }
      }
      guard task.listId != listId || task.parentTaskId != parentTaskId else { return }
      if task.listId != listId {
        let ids = descendants.union([id])
        let values: [Any] = [listId, now] + ids.sorted()
        guard let arguments = StatementArguments(values) else { throw WorkspaceStoreError.invalidTaskMove }
        try db.execute(
          sql: "UPDATE tasks SET listId = ?, updatedAt = ? WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))",
          arguments: arguments)
        task.listId = listId
      }
      task.parentTaskId = parentTaskId
      task.sortOrder = try Self.nextOrder(
        db, table: WorkspaceTask.databaseTableName, whereSQL: "listId = ? AND parentTaskId IS ?",
        arguments: [listId, parentTaskId])
      task.updatedAt = now
      try task.update(db)
    }
  }

  public func moveTaskWithinSiblings(id: String, by offset: Int, now: Date = .now) throws {
    try journalledWrite("Reorder Task") { db in
      guard let task = try WorkspaceTask.fetchOne(db, key: id) else { throw WorkspaceStoreError.missingTask }
      var siblings = try WorkspaceTask.filter(Column("listId") == task.listId && Column("parentTaskId") == task.parentTaskId)
        .order(Column("sortOrder"), Column("createdAt")).fetchAll(db)
      guard let index = siblings.firstIndex(where: { $0.id == id }) else { return }
      let target = min(max(0, index + offset), siblings.count - 1)
      guard target != index else { return }
      let moved = siblings.remove(at: index)
      siblings.insert(moved, at: target)
      try Self.persistTaskOrder(siblings, db: db, now: now)
    }
  }

  /// Places a newly captured task at the top of its project/list. The Today
  /// queue uses this same persistent order, so the first card is first live.
  public func moveTaskToStart(id: String, now: Date = .now) throws {
    try journalledWrite("Reorder Task") { db in
      guard let task = try WorkspaceTask.fetchOne(db, key: id) else { throw WorkspaceStoreError.missingTask }
      var siblings = try WorkspaceTask.filter(Column("listId") == task.listId && Column("parentTaskId") == task.parentTaskId)
        .order(Column("sortOrder"), Column("createdAt")).fetchAll(db)
      guard let index = siblings.firstIndex(where: { $0.id == id }), index > 0 else { return }
      siblings.insert(siblings.remove(at: index), at: 0)
      try Self.persistTaskOrder(siblings, db: db, now: now)
    }
  }

  /// Reorders a card before another card without changing either task's real
  /// list or project parent. Cross-project drops remain a list-move operation.
  public func moveTaskBefore(id: String, targetId: String, kanbanColumn: String? = nil, now: Date = .now) throws {
    try journalledWrite("Reorder Task") { db in
      guard let task = try WorkspaceTask.fetchOne(db, key: id),
        let target = try WorkspaceTask.fetchOne(db, key: targetId)
      else { throw WorkspaceStoreError.missingTask }
      guard task.listId == target.listId, task.parentTaskId == target.parentTaskId else {
        throw WorkspaceStoreError.invalidTaskMove
      }
      guard id != targetId else { return }
      var siblings = try WorkspaceTask.filter(Column("listId") == task.listId && Column("parentTaskId") == task.parentTaskId)
        .order(Column("sortOrder"), Column("createdAt")).fetchAll(db)
      guard let index = siblings.firstIndex(where: { $0.id == id }) else { return }
      let moved = siblings.remove(at: index)
      guard let targetIndex = siblings.firstIndex(where: { $0.id == targetId }) else { return }
      siblings.insert(moved, at: targetIndex)
      try Self.persistTaskOrder(siblings, db: db, now: now)
      if let kanbanColumn {
        try db.execute(sql: """
          INSERT INTO task_metadata(taskId, tagsJSON, externalLinksJSON, kanbanColumn, updatedAt)
          VALUES (?, '[]', '[]', ?, ?)
          ON CONFLICT(taskId) DO UPDATE SET kanbanColumn = excluded.kanbanColumn, updatedAt = excluded.updatedAt
          """, arguments: [id, kanbanColumn, now])
      }
    }
  }

  /// Makes the selected task a child of its immediately preceding sibling.
  public func indentTask(id: String, now: Date = .now) throws {
    try journalledWrite("Indent Task") { db in
      guard var task = try WorkspaceTask.fetchOne(db, key: id) else { throw WorkspaceStoreError.missingTask }
      let siblings = try WorkspaceTask.filter(Column("listId") == task.listId && Column("parentTaskId") == task.parentTaskId)
        .order(Column("sortOrder"), Column("createdAt")).fetchAll(db)
      guard let index = siblings.firstIndex(where: { $0.id == id }), index > 0 else { return }
      let newParent = siblings[index - 1]
      task.parentTaskId = newParent.id
      task.sortOrder = try Self.nextOrder(
        db, table: WorkspaceTask.databaseTableName, whereSQL: "listId = ? AND parentTaskId IS ?",
        arguments: [task.listId, newParent.id])
      task.updatedAt = now
      try task.update(db)
      try Self.persistTaskOrder(siblings.filter { $0.id != id }, db: db, now: now)
    }
  }

  /// Promotes a task one level, immediately after its former parent.
  public func outdentTask(id: String, now: Date = .now) throws {
    try journalledWrite("Outdent Task") { db in
      guard var task = try WorkspaceTask.fetchOne(db, key: id) else { throw WorkspaceStoreError.missingTask }
      guard let parentID = task.parentTaskId, let parent = try WorkspaceTask.fetchOne(db, key: parentID) else { return }
      let newParentID = parent.parentTaskId
      var targetSiblings = try WorkspaceTask.filter(Column("listId") == task.listId && Column("parentTaskId") == newParentID)
        .order(Column("sortOrder"), Column("createdAt")).fetchAll(db)
      let parentIndex = targetSiblings.firstIndex(where: { $0.id == parentID }) ?? (targetSiblings.count - 1)
      task.parentTaskId = newParentID
      task.updatedAt = now
      targetSiblings.insert(task, at: min(parentIndex + 1, targetSiblings.count))
      try Self.persistTaskOrder(targetSiblings, db: db, now: now)
    }
  }

  public func deleteTask(id: String) throws {
    try journalledWrite("Delete Task") { db in
      guard try WorkspaceTask.fetchOne(db, key: id) != nil else { throw WorkspaceStoreError.missingTask }
      try WorkspaceTask.deleteOne(db, key: id)
    }
  }

  static func nextOrder(
    _ db: Database, table: String, whereSQL: String, arguments: StatementArguments
  ) throws -> Int {
    let sql = "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM \(table) WHERE \(whereSQL)"
    return try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
  }

  static func persistTaskOrder(_ tasks: [WorkspaceTask], db: Database, now: Date) throws {
    for (index, var task) in tasks.enumerated() {
      task.sortOrder = index
      task.updatedAt = now
      try task.update(db)
    }
  }

  private static func persistListOrder(_ lists: [TaskList], db: Database, now: Date) throws {
    for (index, var list) in lists.enumerated() {
      list.sortOrder = index
      list.updatedAt = now
      try list.update(db)
    }
  }

  private static func persistFolderOrder(_ folders: [ListFolder], db: Database, now: Date) throws {
    for (index, var folder) in folders.enumerated() {
      folder.sortOrder = index
      folder.updatedAt = now
      try folder.update(db)
    }
  }

  static func taskDescendantIDs(_ db: Database, of taskID: String) throws -> Set<String> {
    var descendants = Set<String>()
    var frontier = [taskID]
    while !frontier.isEmpty {
      let children = try String.fetchAll(
        db, sql: "SELECT id FROM tasks WHERE parentTaskId IN (\(frontier.map { _ in "?" }.joined(separator: ",")))",
        arguments: StatementArguments(frontier))
      frontier = children.filter { descendants.insert($0).inserted }
    }
    return descendants
  }

  static func folderDescendantIDs(_ db: Database, of folderID: String) throws -> Set<String> {
    var descendants = Set<String>()
    var frontier = [folderID]
    while !frontier.isEmpty {
      let children = try String.fetchAll(
        db, sql: "SELECT id FROM list_folders WHERE parentFolderId IN (\(frontier.map { _ in "?" }.joined(separator: ",")))",
        arguments: StatementArguments(frontier))
      frontier = children.filter { descendants.insert($0).inserted }
    }
    return descendants
  }

  private static let migrator: DatabaseMigrator = {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1_local_workspace") { db in
      try db.create(table: "workspaces") { table in
        table.column("id", .text).primaryKey()
        table.column("name", .text).notNull()
        table.column("createdAt", .datetime).notNull()
        table.column("updatedAt", .datetime).notNull()
      }
      try db.create(table: "list_folders") { table in
        table.column("id", .text).primaryKey()
        table.column("workspaceId", .text).notNull().indexed().references("workspaces", onDelete: .cascade)
        table.column("parentFolderId", .text).indexed().references("list_folders", onDelete: .cascade)
        table.column("name", .text).notNull()
        table.column("sortOrder", .integer).notNull()
        table.column("createdAt", .datetime).notNull()
        table.column("updatedAt", .datetime).notNull()
      }
      try db.create(table: "task_lists") { table in
        table.column("id", .text).primaryKey()
        table.column("workspaceId", .text).notNull().indexed().references("workspaces", onDelete: .cascade)
        table.column("folderId", .text).indexed().references("list_folders", onDelete: .setNull)
        table.column("name", .text).notNull()
        table.column("colorHex", .text)
        table.column("sortOrder", .integer).notNull()
        table.column("isArchived", .boolean).notNull().defaults(to: false)
        table.column("createdAt", .datetime).notNull()
        table.column("updatedAt", .datetime).notNull()
      }
      try db.create(table: "tasks") { table in
        table.column("id", .text).primaryKey()
        table.column("listId", .text).notNull().indexed().references("task_lists", onDelete: .cascade)
        table.column("parentTaskId", .text).indexed().references("tasks", onDelete: .cascade)
        table.column("title", .text).notNull()
        table.column("notes", .text).notNull().defaults(to: "")
        table.column("status", .text).notNull().defaults(to: TaskStatus.open.rawValue)
        table.column("sortOrder", .integer).notNull()
        table.column("dueAt", .datetime)
        table.column("estimateSeconds", .integer)
        table.column("createdAt", .datetime).notNull()
        table.column("updatedAt", .datetime).notNull()
      }
    }
    migrator.registerMigration("v2_metadata_and_focus") { db in
      try db.create(table: "task_metadata") { table in
        table.column("taskId", .text).primaryKey().references("tasks", onDelete: .cascade)
        table.column("priority", .integer)
        table.column("startAt", .datetime)
        table.column("tagsJSON", .text).notNull().defaults(to: "[]")
        table.column("recurrenceRule", .text)
        table.column("matrixUrgency", .integer)
        table.column("matrixImportance", .integer)
        table.column("kanbanColumn", .text)
        table.column("externalLinksJSON", .text).notNull().defaults(to: "[]")
        table.column("updatedAt", .datetime).notNull()
      }
      try db.create(table: "focus_sessions") { table in
        table.column("id", .text).primaryKey()
        table.column("startedAt", .datetime).notNull().indexed()
        table.column("endedAt", .datetime)
        table.column("phase", .text).notNull()
        table.column("activeTaskId", .text).references("tasks", onDelete: .setNull)
        table.column("workDurationSeconds", .integer).notNull()
        table.column("breakDurationSeconds", .integer).notNull()
        table.column("breakEndsAt", .datetime)
      }
      try db.create(table: "focus_queue_items") { table in
        table.column("id", .text).primaryKey()
        table.column("sessionId", .text).notNull().indexed().references("focus_sessions", onDelete: .cascade)
        table.column("taskId", .text).notNull().indexed().references("tasks", onDelete: .cascade)
        table.column("sortOrder", .integer).notNull()
        table.column("state", .text).notNull().defaults(to: FocusQueueState.queued.rawValue)
        table.column("completedAt", .datetime)
        table.column("skippedAt", .datetime)
        table.column("createdAt", .datetime).notNull()
      }
    }
    migrator.registerMigration("v3_dailies_as_contributions") { db in
      try db.create(table: "dailies") { table in
        table.column("id", .text).primaryKey()
        table.column("taskId", .text).notNull().indexed().references("tasks", onDelete: .cascade)
        table.column("activeWeekdaysMask", .integer).notNull().defaults(to: WorkspaceDaily.allWeekdaysMask)
        table.column("intervalDays", .integer)
        table.column("intervalAnchor", .datetime)
        table.column("targetSeconds", .integer)
        table.column("sortOrder", .integer).notNull()
        table.column("archivedAt", .datetime)
        // The id of the plugin-era daily this came from, so the one-time
        // import can run again without producing a second copy.
        table.column("legacyDailyId", .text).unique()
        table.column("createdAt", .datetime).notNull()
        table.column("updatedAt", .datetime).notNull()
      }
      try db.create(table: "daily_contributions") { table in
        table.column("id", .text).primaryKey()
        table.column("dailyId", .text).notNull().indexed().references("dailies", onDelete: .cascade)
        table.column("taskId", .text).notNull().indexed().references("tasks", onDelete: .cascade)
        table.column("dayKey", .text).notNull()
        table.column("secondsLogged", .integer).notNull().defaults(to: 0)
        table.column("completedAt", .datetime)
        table.column("createdAt", .datetime).notNull()
        // One row per daily per day: a contribution accumulates into the
        // existing row rather than appending a second one.
        table.uniqueKey(["dailyId", "dayKey"])
      }
      // The estimate the focus screen was started with, which is not the task's
      // standing estimate — "this sitting" and "this job" are different numbers.
      try db.alter(table: "focus_queue_items") { table in
        table.add(column: "plannedSeconds", .integer)
      }
    }
    migrator.registerMigration("v4_manual_focus_order") { db in
      // A hand-placed position in the focus ladder. Null means "not arranged by
      // hand" — those tasks keep following the ranking underneath.
      try db.alter(table: "task_metadata") { table in
        table.add(column: "focusRank", .integer)
      }
    }
    migrator.registerMigration("v5_task_source_identity") { db in
      // Immutable once written: what an outside service calls this task. The
      // pair is what makes a second import run a merge rather than a copy.
      try db.alter(table: "tasks") { table in
        table.add(column: "sourceSystem", .text)
        table.add(column: "sourceId", .text)
      }
      // Partial, so the many locally created tasks — all of which have a null
      // sourceId — do not collide with each other in the index.
      try db.execute(sql: """
        CREATE UNIQUE INDEX tasks_on_source
        ON tasks(sourceSystem, sourceId) WHERE sourceId IS NOT NULL
        """)
    }
    migrator.registerMigration("v6_inbox_as_a_system_list") { db in
      try db.alter(table: "task_lists") { table in
        table.add(column: "systemRole", .text)
      }
      // Claim the list that has been acting as the inbox rather than adding a
      // second one beside it. Oldest wins, so a user who made their own list
      // called Inbox later keeps it as an ordinary list.
      try db.execute(sql: """
        UPDATE task_lists SET systemRole = 'inbox' WHERE id IN (
          SELECT id FROM task_lists AS candidate
          WHERE lower(candidate.name) = 'inbox'
            AND candidate.createdAt = (
              SELECT MIN(earliest.createdAt) FROM task_lists AS earliest
              WHERE lower(earliest.name) = 'inbox' AND earliest.workspaceId = candidate.workspaceId
            )
          GROUP BY candidate.workspaceId
        )
        """)
      try db.execute(sql: """
        CREATE UNIQUE INDEX task_lists_on_system_role
        ON task_lists(workspaceId, systemRole) WHERE systemRole IS NOT NULL
        """)
    }
    migrator.registerMigration("v7_task_full_text_search") { db in
      // External-content FTS5: the index stores no task text of its own, and
      // `synchronize` writes the triggers that keep it level with the tasks
      // table, so no mutation path has to remember to update the index.
      try db.create(virtualTable: "tasks_fts", using: FTS5()) { table in
        table.synchronize(withTable: "tasks")
        table.column("title")
        table.column("notes")
        // Porter over unicode61, so "meeting" finds "meetings" and a search
        // for "cafe" finds "café".
        table.tokenizer = .porter(wrapping: .unicode61())
      }
    }
    migrator.registerMigration("v8_undo_journal") { db in
      try db.create(table: "undo_control") { table in
        table.column("id", .integer).primaryKey()
        // The step any recorded change belongs to, set by `journalledWrite`.
        table.column("groupId", .text)
        table.column("label", .text)
        // Recording is off unless a journalled write turns it on, so imports
        // and migrations do not arrive as thousands of undo steps.
        table.column("suppressed", .integer).notNull().defaults(to: 1)
      }
      try db.execute(sql: "INSERT INTO undo_control (id, suppressed) VALUES (0, 1)")
      try db.create(table: "change_log") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("groupId", .text).indexed()
        table.column("label", .text)
        table.column("tableName", .text).notNull()
        table.column("rowId", .text).notNull()
        table.column("operation", .text).notNull()
        table.column("beforeJSON", .text)
        table.column("afterJSON", .text)
        table.column("undone", .boolean).notNull().defaults(to: false)
      }
      try WorkspaceStore.installChangeLogTriggers(db)
    }
    migrator.registerMigration("v9_focus_block_start") { db in
      try db.alter(table: "focus_sessions") { table in
        // The default exists only because SQLite needs one to add a NOT NULL
        // column to a table with rows in it; every existing row is overwritten
        // on the next line, and every new row carries its own value.
        table.add(column: "activeTaskStartedAt", .datetime)
          .notNull().defaults(to: Date(timeIntervalSince1970: 0))
      }
      // Existing sessions only ever had one clock, so the session's start is
      // the truest answer available for the block that was running.
      try db.execute(sql: "UPDATE focus_sessions SET activeTaskStartedAt = startedAt")
    }
    migrator.registerMigration("v10_focus_points") { db in
      try db.create(table: "focus_awards") { table in
        table.column("id", .text).primaryKey()
        // Both references let go rather than cascade: deleting a task or
        // clearing out old sessions must not take the score with it.
        table.column("sessionId", .text).references("focus_sessions", onDelete: .setNull)
        table.column("taskId", .text).references("tasks", onDelete: .setNull)
        table.column("taskTitle", .text).notNull()
        table.column("seconds", .integer).notNull()
        table.column("minutes", .double).notNull()
        table.column("multiplier", .double).notNull()
        table.column("points", .double).notNull()
        table.column("awardedAt", .datetime).notNull().indexed()
      }
    }
    migrator.registerMigration("v11_stable_visible_roots") { db in
      // Nullable for older undo snapshots, which predate this column.
      try db.alter(table: "task_lists") { table in
        table.add(column: "visibleRootTaskId", .text).references("tasks", onDelete: .setNull)
      }
      for list in try TaskList.fetchAll(db) {
        try WorkspaceStore.registerVisibleRoot(db, for: list)
      }
      // Carry the inferred identity into pre-upgrade list snapshots as well,
      // so undoing an old colour/name edit does not unhide its wrapper.
      try db.execute(sql: """
        UPDATE change_log SET
          beforeJSON = CASE WHEN beforeJSON IS NULL THEN NULL ELSE
            json_set(beforeJSON, '$.visibleRootTaskId',
              (SELECT visibleRootTaskId FROM task_lists WHERE id = change_log.rowId)) END,
          afterJSON = CASE WHEN afterJSON IS NULL THEN NULL ELSE
            json_set(afterJSON, '$.visibleRootTaskId',
              (SELECT visibleRootTaskId FROM task_lists WHERE id = change_log.rowId)) END
        WHERE tableName = 'task_lists'
        """)
      try WorkspaceStore.installChangeLogTriggers(db)
    }
    migrator.registerMigration("v12_task_conditions_and_work") { db in
      try db.create(table: "task_conditions") { table in
        table.column("id", .text).primaryKey()
        table.column("workspaceId", .text).notNull().references("workspaces", onDelete: .cascade)
        table.column("name", .text).notNull()
        table.column("isLocation", .boolean).notNull().defaults(to: false)
        table.column("isArchived", .boolean).notNull().defaults(to: false)
        table.column("createdAt", .datetime).notNull()
        table.column("updatedAt", .datetime).notNull()
      }
      for workspace in try Workspace.fetchAll(db) {
        try WorkspaceStore.seedConditions(db, workspaceId: workspace.id, now: .now)
      }
      try db.alter(table: "task_metadata") { table in table.add(column: "planningJSON", .text) }
      try db.alter(table: "focus_sessions") { table in
        table.add(column: "activeBlockId", .text)
        table.add(column: "accumulatedSeconds", .integer)
        table.add(column: "pausedAt", .datetime)
        table.add(column: "checkpointAt", .datetime)
      }
      try db.create(table: "focus_work_blocks") { table in
        table.column("id", .text).primaryKey()
        table.column("sessionId", .text).references("focus_sessions", onDelete: .setNull)
        table.column("taskId", .text).indexed().references("tasks", onDelete: .setNull)
        table.column("taskTitle", .text).notNull()
        table.column("seconds", .integer).notNull()
        table.column("recordedAt", .datetime).notNull()
        table.column("originalTaskId", .text).indexed()
      }
      try db.execute(sql: """
        INSERT INTO focus_work_blocks(id, sessionId, taskId, taskTitle, seconds, recordedAt, originalTaskId)
        SELECT 'legacy-' || id, sessionId, taskId, taskTitle, seconds, awardedAt, taskId FROM focus_awards
        """)
      try WorkspaceStore.installChangeLogTriggers(db)
    }
    migrator.registerMigration("v13_legacy_visible_roots") { db in
      // Early bulk imports predate source identity. Recognise only matching
      // wrappers created in the same batch as their list and children.
      for var list in try TaskList.fetchAll(db) where list.visibleRootTaskId == nil {
        let roots = try WorkspaceTask
          .filter(Column("listId") == list.id && Column("parentTaskId") == nil).fetchAll(db)
        guard roots.count == 1, let root = roots.first,
          root.sourceSystem == nil, root.createdAt == list.createdAt,
          !normalizedVisibleRootName(list.name).isEmpty,
          normalizedVisibleRootName(root.title) == normalizedVisibleRootName(list.name),
          try WorkspaceTask.filter(Column("parentTaskId") == root.id
            && Column("createdAt") == list.createdAt).fetchCount(db) > 0
        else { continue }
        list.visibleRootTaskId = root.id
        try list.update(db)
      }
    }
    migrator.registerMigration("v14_nested_lists") { db in
      try db.alter(table: "tasks") { table in
        table.add(column: "itemKind", .text)
        table.add(column: "isPromoted", .boolean)
        table.add(column: "archivedAt", .datetime)
      }
      try db.alter(table: "task_lists") { table in
        table.add(column: "completedAt", .datetime)
      }
      // Nullable additions also keep pre-migration undo snapshots valid.
      try installChangeLogTriggers(db)
    }
    migrator.registerMigration("v15_kanban_board_history") { db in
      try db.create(table: "kanban_boards") { table in
        table.column("id", .text).primaryKey()
        table.column("columnsJSON", .text).notNull()
      }
      try WorkspaceStore.installChangeLogTriggers(db)
    }
    migrator.registerMigration("v16_task_completion_time") { db in
      try db.alter(table: "tasks") { table in
        table.add(column: "completedAt", .datetime)
      }
      // Existing rows only know when they were last touched. For a task that
      // is already closed that is the closest thing to a completion date the
      // schema ever recorded, so it is backfilled rather than left null —
      // a week's history that starts empty would read as a week of no work.
      try db.execute(sql: """
        UPDATE tasks SET completedAt = updatedAt
        WHERE status = 'completed' AND completedAt IS NULL
        """)
      try WorkspaceStore.installChangeLogTriggers(db)
    }
    migrator.registerMigration("v17_sync") { db in
      try WorkspaceStore.createSyncTables(db)
      try WorkspaceStore.installSyncTriggers(db)
    }
    migrator.registerMigration("v18_themes_and_preferences") { db in
      // Synced, so the outbox triggers are reinstalled to cover them. Not
      // journalled for undo, so `installChangeLogTriggers` is not.
      try WorkspaceStore.createThemeAndPreferenceTables(db)
      try WorkspaceStore.installSyncTriggers(db)
    }

    return migrator
  }()
}

public enum WorkspaceStoreError: LocalizedError, Equatable {
  case emptyName
  case duplicateLegacySourceID
  case missingTask
  case missingDaily
  case noActiveFocusTask
  case missingList
  case missingFolder
  case invalidTaskMove
  case invalidFolderMove
  case systemListIsPermanent

  public var errorDescription: String? {
    switch self {
    case .emptyName: return "A workspace item needs a name."
    case .duplicateLegacySourceID: return "The legacy task store contains duplicate task IDs."
    case .missingTask: return "That task is no longer available."
    case .missingDaily: return "That daily is no longer available."
    case .noActiveFocusTask: return "This focus session has no active task."
    case .missingList: return "That list is no longer available."
    case .missingFolder: return "That folder is no longer available."
    case .invalidTaskMove: return "A task cannot be moved into itself or one of its subtasks."
    case .invalidFolderMove: return "A folder cannot be moved into itself or one of its subfolders."
    case .systemListIsPermanent: return "The Inbox cannot be archived or deleted. You can rename it instead."
    }
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
