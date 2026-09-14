import Foundation
import GRDB

/// The local source of truth for Priority's desktop workspace.
///
/// It intentionally has no knowledge of Checkvist or app UI. External services
/// translate their data into local records at the edge, so normal task editing
/// never needs network access.
public final class WorkspaceStore: @unchecked Sendable {
  private let database: DatabasePool

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
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return root.appending(path: "Priority/priority.sqlite", directoryHint: .notDirectory)
  }

  @discardableResult
  public func bootstrapIfNeeded(now: Date = .now) throws -> Workspace {
    if let workspace = try database.read({ db in try Workspace.fetchOne(db) }) {
      return workspace
    }

    let workspace = Workspace(id: UUID().uuidString, name: "My Workspace", createdAt: now, updatedAt: now)
    let inbox = TaskList(
      id: UUID().uuidString,
      workspaceId: workspace.id,
      folderId: nil,
      name: "Inbox",
      colorHex: nil,
      sortOrder: 0,
      isArchived: false,
      createdAt: now,
      updatedAt: now)
    try database.write { db in
      try workspace.insert(db)
      try inbox.insert(db)
    }
    return workspace
  }

  public func workspaces() throws -> [Workspace] {
    try database.read { db in
      try Workspace.order(Column("createdAt")).fetchAll(db)
    }
  }

  public func folders(in workspaceId: String) throws -> [ListFolder] {
    try database.read { db in
      try ListFolder.filter(Column("workspaceId") == workspaceId)
        .order(Column("sortOrder"), Column("name")).fetchAll(db)
    }
  }

  public func lists(in workspaceId: String, includingArchived: Bool = false) throws -> [TaskList] {
    try database.read { db in
      var request = TaskList.filter(Column("workspaceId") == workspaceId)
      if !includingArchived { request = request.filter(Column("isArchived") == false) }
      return try request.order(Column("sortOrder"), Column("name")).fetchAll(db)
    }
  }

  public func createFolder(
    workspaceId: String,
    name: String,
    parentFolderId: String? = nil,
    now: Date = .now
  ) throws -> ListFolder {
    let trimmed = try Self.nonEmptyName(name)
    return try database.write { db in
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
    return try database.write { db in
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

  public func outline(in listId: String, parentTaskId: String? = nil) throws -> [TaskOutlineItem] {
    let tasks = try database.read { db in
      try WorkspaceTask.filter(Column("listId") == listId)
        .order(Column("sortOrder"), Column("createdAt")).fetchAll(db)
    }
    let children = Dictionary(grouping: tasks, by: \.parentTaskId)
    var result: [TaskOutlineItem] = []
    var visited = Set<String>()

    func append(_ parent: String?, depth: Int) {
      for task in children[parent, default: []] where visited.insert(task.id).inserted {
        result.append(TaskOutlineItem(task: task, depth: depth))
        append(task.id, depth: depth + 1)
      }
    }

    append(parentTaskId, depth: 0)
    return result
  }

  public func createTask(
    listId: String,
    title: String,
    parentTaskId: String? = nil,
    now: Date = .now
  ) throws -> WorkspaceTask {
    let trimmed = try Self.nonEmptyName(title)
    return try database.write { db in
      let nextOrder = try Self.nextOrder(
        db, table: WorkspaceTask.databaseTableName, whereSQL: "listId = ? AND parentTaskId IS ?",
        arguments: [listId, parentTaskId])
      let task = WorkspaceTask(
        id: UUID().uuidString, listId: listId, parentTaskId: parentTaskId, title: trimmed,
        notes: "", status: .open, sortOrder: nextOrder, dueAt: nil, estimateSeconds: nil,
        createdAt: now, updatedAt: now)
      try task.insert(db)
      return task
    }
  }

  public func setStatus(_ status: TaskStatus, for taskId: String, now: Date = .now) throws {
    try database.write { db in
      guard var task = try WorkspaceTask.fetchOne(db, key: taskId) else { return }
      task.status = status
      task.updatedAt = now
      try task.update(db)
    }
  }

  /// Imports the previous offline store once. Broken source parent links become
  /// roots instead of losing the task, and duplicate source IDs are rejected.
  @discardableResult
  public func importLegacyTasks(
    workspaceId: String,
    listName: String,
    seeds: [LegacyTaskSeed],
    now: Date = .now
  ) throws -> TaskList? {
    guard !seeds.isEmpty else { return nil }
    guard Set(seeds.map(\.sourceId)).count == seeds.count else {
      throw WorkspaceStoreError.duplicateLegacySourceID
    }
    return try database.write { db in
      let listOrder = try Self.nextOrder(
        db, table: TaskList.databaseTableName, whereSQL: "workspaceId = ? AND folderId IS ?",
        arguments: [workspaceId, nil])
      let list = TaskList(
        id: UUID().uuidString, workspaceId: workspaceId, folderId: nil, name: listName,
        colorHex: nil, sortOrder: listOrder, isArchived: false, createdAt: now, updatedAt: now)
      try list.insert(db)

      let localIDBySourceID = Dictionary(uniqueKeysWithValues: seeds.map { ($0.sourceId, UUID().uuidString) })
      let sourceIDs = Set(seeds.map(\.sourceId))
      var insertedSourceIDs = Set<String>()
      var remaining = seeds
      while !remaining.isEmpty {
        let nextIndex = remaining.firstIndex { seed in
          guard let parent = seed.parentSourceId else { return true }
          return !sourceIDs.contains(parent) || insertedSourceIDs.contains(parent)
        }
        // A cyclic legacy hierarchy cannot be represented with foreign keys.
        // Keep every task by promoting one cycle member to a local root.
        let seed = remaining.remove(at: nextIndex ?? 0)
        let parent = nextIndex == nil
          ? nil
          : seed.parentSourceId.flatMap { localIDBySourceID[$0] }
        let task = WorkspaceTask(
          id: localIDBySourceID[seed.sourceId]!, listId: list.id, parentTaskId: parent,
          title: seed.title, notes: seed.notes, status: seed.status, sortOrder: seed.sortOrder,
          dueAt: nil, estimateSeconds: nil, createdAt: now, updatedAt: now)
        try task.insert(db)
        insertedSourceIDs.insert(seed.sourceId)
      }
      return list
    }
  }

  private static func nonEmptyName(_ raw: String) throws -> String {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { throw WorkspaceStoreError.emptyName }
    return value
  }

  private static func nextOrder(
    _ db: Database, table: String, whereSQL: String, arguments: StatementArguments
  ) throws -> Int {
    let sql = "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM \(table) WHERE \(whereSQL)"
    return try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
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
    return migrator
  }()
}

public enum WorkspaceStoreError: LocalizedError, Equatable {
  case emptyName
  case duplicateLegacySourceID

  public var errorDescription: String? {
    switch self {
    case .emptyName: return "A workspace item needs a name."
    case .duplicateLegacySourceID: return "The legacy task store contains duplicate task IDs."
    }
  }
}
