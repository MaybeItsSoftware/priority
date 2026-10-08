import Foundation
import GRDB
import TaktRustCore
import TaktCore

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
    // The CLI writes this file too, under `BEGIN IMMEDIATE`, and sets a
    // five-second busy timeout of its own (`cli/src/workspace_tasks.rs`).
    // GRDB's default is to fail at once, so without this an app write that
    // lands while the CLI holds the lock throws and the keystroke is lost.
    configuration.busyMode = .timeout(5)
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
    }
    // The schema is the Rust core's (core/src/schema, step two of
    // docs/rust-core-migration.md): it opens the file, brings it up to date
    // under GRDB's own `grdb_migrations` ledger, and closes it again before
    // the pool opens, so the two never hold the file at once.
    _ = try migrateWorkspace(path: databaseURL.path)
    self.database = try DatabasePool(path: databaseURL.path, configuration: configuration)
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

  static func normalizedVisibleRootName(_ name: String) -> String {
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
    waitingOn: String? = nil,
    now: Date = .now
  ) throws -> WorkspaceTask {
    let trimmed = try Self.nonEmptyName(title)
    // Waiting on someone puts it in that column, as `setWaiting` does.
    let waitingOn = WaitingFollowUp.normalizedTag(waitingOn)
    let kanbanColumn = waitingOn != nil ? WaitingFollowUp.waitingColumnID : kanbanColumn
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
      if kanbanColumn != nil || startAt != nil || !tags.isEmpty || priority != nil || waitingOn != nil {
        let tagsJSON = String(data: try JSONEncoder().encode(tags), encoding: .utf8) ?? "[]"
        try db.execute(sql: """
          INSERT INTO task_metadata(taskId, priority, startAt, tagsJSON, externalLinksJSON, kanbanColumn, waitingOn,
            updatedAt)
          VALUES (?, ?, ?, ?, '[]', ?, ?, ?)
          """, arguments: [task.id, priority, startAt, tagsJSON, kanbanColumn, waitingOn, now])
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
        try Self.expireHabits(db, sourceTaskId: task.id, now: now)
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
