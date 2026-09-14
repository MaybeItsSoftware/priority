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

  public func updateTask(
    id: String,
    title: String,
    notes: String,
    dueAt: Date?,
    estimateSeconds: Int?,
    now: Date = .now
  ) throws {
    let trimmed = try Self.nonEmptyName(title)
    try database.write { db in
      guard var task = try WorkspaceTask.fetchOne(db, key: id) else { return }
      task.title = trimmed
      task.notes = notes
      task.dueAt = dueAt
      task.estimateSeconds = estimateSeconds
      task.updatedAt = now
      try task.update(db)
    }
  }

  public func activeFocusSession() throws -> FocusSession? {
    try database.read { db in
      try FocusSession.filter(Column("phase") != FocusSessionPhase.finished.rawValue)
        .order(Column("startedAt").desc).fetchOne(db)
    }
  }

  public func focusQueue(for sessionId: String) throws -> [FocusQueueTask] {
    try database.read { db in
      let items = try FocusQueueItem.filter(Column("sessionId") == sessionId)
        .order(Column("sortOrder"), Column("createdAt")).fetchAll(db)
      return try items.compactMap { item in
        guard let task = try WorkspaceTask.fetchOne(db, key: item.taskId) else { return nil }
        return FocusQueueTask(item: item, task: task)
      }
    }
  }

  public func startFocusSession(
    taskId: String,
    workDurationSeconds: Int = 25 * 60,
    breakDurationSeconds: Int = 5 * 60,
    now: Date = .now
  ) throws -> FocusSession {
    try database.write { db in
      if let active = try FocusSession.filter(Column("phase") != FocusSessionPhase.finished.rawValue).fetchOne(db) {
        return active
      }
      guard try WorkspaceTask.fetchOne(db, key: taskId) != nil else {
        throw WorkspaceStoreError.missingTask
      }
      let session = FocusSession(
        id: UUID().uuidString, startedAt: now, endedAt: nil, phase: .running, activeTaskId: taskId,
        workDurationSeconds: max(60, workDurationSeconds), breakDurationSeconds: max(60, breakDurationSeconds),
        breakEndsAt: nil)
      let firstItem = FocusQueueItem(
        id: UUID().uuidString, sessionId: session.id, taskId: taskId, sortOrder: 0, state: .queued,
        completedAt: nil, skippedAt: nil, createdAt: now)
      try session.insert(db)
      try firstItem.insert(db)
      return session
    }
  }

  public func addToFocusQueue(sessionId: String, taskId: String, now: Date = .now) throws {
    try database.write { db in
      guard try FocusSession.fetchOne(db, key: sessionId) != nil,
        try WorkspaceTask.fetchOne(db, key: taskId) != nil
      else { throw WorkspaceStoreError.missingTask }
      if try FocusQueueItem.filter(Column("sessionId") == sessionId && Column("taskId") == taskId)
        .fetchOne(db) != nil
      {
        return
      }
      let count = try FocusQueueItem.filter(Column("sessionId") == sessionId)
        .fetchCount(db)
      let item = FocusQueueItem(
        id: UUID().uuidString, sessionId: sessionId, taskId: taskId, sortOrder: count, state: .queued,
        completedAt: nil, skippedAt: nil, createdAt: now)
      try item.insert(db)
    }
  }

  public func completeActiveFocusTask(sessionId: String, now: Date = .now) throws -> FocusSession {
    try database.write { db in
      guard var session = try FocusSession.fetchOne(db, key: sessionId), let activeID = session.activeTaskId else {
        throw WorkspaceStoreError.noActiveFocusTask
      }
      if var task = try WorkspaceTask.fetchOne(db, key: activeID) {
        task.status = .completed
        task.updatedAt = now
        try task.update(db)
      }
      if var item = try FocusQueueItem.filter(Column("sessionId") == sessionId && Column("taskId") == activeID)
        .filter(Column("state") == FocusQueueState.queued.rawValue).fetchOne(db)
      {
        item.state = .completed
        item.completedAt = now
        try item.update(db)
      }
      let next = try FocusQueueItem.filter(Column("sessionId") == sessionId)
        .filter(Column("state") == FocusQueueState.queued.rawValue)
        .order(Column("sortOrder")).fetchOne(db)
      session.activeTaskId = next?.taskId
      if next == nil {
        session.phase = .finished
        session.endedAt = now
      }
      try session.update(db)
      return session
    }
  }

  public func finishFocusSession(id: String, now: Date = .now) throws {
    try database.write { db in
      guard var session = try FocusSession.fetchOne(db, key: id) else { return }
      session.phase = .finished
      session.endedAt = now
      session.breakEndsAt = nil
      try session.update(db)
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
    return migrator
  }()
}

public enum WorkspaceStoreError: LocalizedError, Equatable {
  case emptyName
  case duplicateLegacySourceID
  case missingTask
  case noActiveFocusTask

  public var errorDescription: String? {
    switch self {
    case .emptyName: return "A workspace item needs a name."
    case .duplicateLegacySourceID: return "The legacy task store contains duplicate task IDs."
    case .missingTask: return "That task is no longer available."
    case .noActiveFocusTask: return "This focus session has no active task."
    }
  }
}
