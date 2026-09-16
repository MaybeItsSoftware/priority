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
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return root.appending(path: "Priority/priority.sqlite", directoryHint: .notDirectory)
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
      folder.name = trimmed
      folder.updatedAt = now
      try folder.update(db)
    }
  }

  public func moveFolder(id: String, toParentFolderId parentFolderId: String?, now: Date = .now) throws {
    try journalledWrite("Move Folder") { db in
      guard var folder = try ListFolder.fetchOne(db, key: id) else { throw WorkspaceStoreError.missingFolder }
      guard parentFolderId != id else { throw WorkspaceStoreError.invalidFolderMove }
      if let parentFolderId {
        guard let parent = try ListFolder.fetchOne(db, key: parentFolderId), parent.workspaceId == folder.workspaceId else {
          throw WorkspaceStoreError.missingFolder
        }
        if try Self.folderDescendantIDs(db, of: id).contains(parentFolderId) {
          throw WorkspaceStoreError.invalidFolderMove
        }
      }
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
    try journalledWrite("Edit List") { db in
      guard var list = try TaskList.fetchOne(db, key: id) else { throw WorkspaceStoreError.missingList }
      list.name = trimmed
      list.colorHex = colorHex?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
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
        .order(Column("sortOrder"), Column("createdAt")).fetchAll(db)
      guard let index = siblings.firstIndex(where: { $0.id == id }) else { return }
      let target = min(max(0, index + offset), siblings.count - 1)
      guard target != index else { return }
      siblings.insert(siblings.remove(at: index), at: target)
      try Self.persistListOrder(siblings, db: db, now: now)
    }
  }

  public func moveFolderWithinSiblings(id: String, by offset: Int, now: Date = .now) throws {
    try journalledWrite("Reorder Folder") { db in
      guard let folder = try ListFolder.fetchOne(db, key: id) else { throw WorkspaceStoreError.missingFolder }
      var siblings = try ListFolder
        .filter(Column("workspaceId") == folder.workspaceId && Column("parentFolderId") == folder.parentFolderId)
        .order(Column("sortOrder"), Column("createdAt")).fetchAll(db)
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

  /// Returns a transport root only when it is the sole top-level task and
  /// repeats the list name. Its children are the visible list-level work.
  public func visibleRootParentTaskID(for list: TaskList) throws -> String? {
    let roots = try tasks(in: list.id)
    guard roots.count == 1, let root = roots.first,
      Self.normalizedVisibleRootName(root.title) == Self.normalizedVisibleRootName(list.name)
    else { return nil }
    return root.id
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
      .replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression)
  }

  public func createTask(
    listId: String,
    title: String,
    parentTaskId: String? = nil,
    now: Date = .now
  ) throws -> WorkspaceTask {
    let trimmed = try Self.nonEmptyName(title)
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
        notes: "", status: .open, sortOrder: nextOrder, dueAt: nil, estimateSeconds: nil,
        createdAt: now, updatedAt: now)
      try task.insert(db)
      return task
    }
  }

  public func setStatus(_ status: TaskStatus, for taskId: String, now: Date = .now) throws {
    try journalledWrite("Change Status") { db in
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
    try journalledWrite("Edit Task") { db in
      guard var task = try WorkspaceTask.fetchOne(db, key: id) else { return }
      task.title = trimmed
      task.notes = notes
      task.dueAt = dueAt
      task.estimateSeconds = estimateSeconds
      task.updatedAt = now
      try task.update(db)
    }
  }

  public func taskEditorMetadata(for taskId: String) throws -> TaskEditorMetadata {
    try database.read { db in
      guard let metadata = try TaskMetadata.fetchOne(db, key: taskId) else { return TaskEditorMetadata() }
      return TaskEditorMetadata(
        priority: metadata.priority,
        tags: Self.decodeStringArray(metadata.tagsJSON),
        recurrenceRule: metadata.recurrenceRule,
        externalLinks: Self.decodeStringArray(metadata.externalLinksJSON))
    }
  }

  public func updateTaskEditorMetadata(
    taskId: String,
    metadata: TaskEditorMetadata,
    now: Date = .now
  ) throws {
    let tags = Self.normalizedStrings(metadata.tags)
    let links = Self.normalizedStrings(metadata.externalLinks)
    let recurrence = metadata.recurrenceRule?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    let priority = metadata.priority.flatMap { (1...4).contains($0) ? $0 : nil }
    try journalledWrite("Edit Task Details") { db in
      guard try WorkspaceTask.fetchOne(db, key: taskId) != nil else { throw WorkspaceStoreError.missingTask }
      let tagsJSON = String(data: try JSONEncoder().encode(tags), encoding: .utf8) ?? "[]"
      let linksJSON = String(data: try JSONEncoder().encode(links), encoding: .utf8) ?? "[]"
      var record = try TaskMetadata.fetchOne(db, key: taskId) ?? TaskMetadata(
        taskId: taskId, priority: nil, startAt: nil, tagsJSON: "[]", recurrenceRule: nil,
        matrixUrgency: nil, matrixImportance: nil, kanbanColumn: nil, externalLinksJSON: "[]", updatedAt: now)
      record.priority = priority
      record.tagsJSON = tagsJSON
      record.recurrenceRule = recurrence
      record.externalLinksJSON = linksJSON
      record.updatedAt = now
      if try TaskMetadata.fetchOne(db, key: taskId) == nil {
        try record.insert(db)
      } else {
        try record.update(db)
      }
    }
  }

  public func kanbanColumn(for taskId: String) throws -> String? {
    try database.read { db in try TaskMetadata.fetchOne(db, key: taskId)?.kanbanColumn }
  }

  public func setKanbanColumn(_ column: String?, for taskId: String, now: Date = .now) throws {
    try journalledWrite("Move Task") { db in
      guard try WorkspaceTask.fetchOne(db, key: taskId) != nil else { throw WorkspaceStoreError.missingTask }
      var record = try TaskMetadata.fetchOne(db, key: taskId) ?? TaskMetadata(
        taskId: taskId, priority: nil, startAt: nil, tagsJSON: "[]", recurrenceRule: nil,
        matrixUrgency: nil, matrixImportance: nil, kanbanColumn: nil, externalLinksJSON: "[]", updatedAt: now)
      record.kanbanColumn = column?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      record.updatedAt = now
      if try TaskMetadata.fetchOne(db, key: taskId) == nil {
        try record.insert(db)
      } else {
        try record.update(db)
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
  public func moveTask(id: String, toListId listId: String, parentTaskId: String? = nil, now: Date = .now) throws {
    try journalledWrite("Move Task") { db in
      guard var task = try WorkspaceTask.fetchOne(db, key: id) else { throw WorkspaceStoreError.missingTask }
      guard try TaskList.fetchOne(db, key: listId) != nil else { throw WorkspaceStoreError.missingList }
      let descendants = try Self.taskDescendantIDs(db, of: id)
      guard parentTaskId != id, parentTaskId.map({ !descendants.contains($0) }) ?? true else {
        throw WorkspaceStoreError.invalidTaskMove
      }
      if let parentTaskId {
        guard let parent = try WorkspaceTask.fetchOne(db, key: parentTaskId), parent.listId == listId else {
          throw WorkspaceStoreError.invalidTaskMove
        }
      }
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
  public func moveTaskBefore(id: String, targetId: String, now: Date = .now) throws {
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

  /// `plannedSeconds` is the estimate given on the focus screen. It becomes the
  /// session's work block, so the timer counts towards the number the user
  /// actually committed to rather than a fixed pomodoro they never chose.
  public func startFocusSession(
    taskId: String,
    plannedSeconds: Int? = nil,
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
        workDurationSeconds: max(60, plannedSeconds ?? workDurationSeconds),
        breakDurationSeconds: max(60, breakDurationSeconds),
        breakEndsAt: nil)
      let firstItem = FocusQueueItem(
        id: UUID().uuidString, sessionId: session.id, taskId: taskId, sortOrder: 0, state: .queued,
        plannedSeconds: plannedSeconds, completedAt: nil, skippedAt: nil, createdAt: now)
      try session.insert(db)
      try firstItem.insert(db)
      return session
    }
  }

  public func addToFocusQueue(
    sessionId: String, taskId: String, plannedSeconds: Int? = nil, now: Date = .now
  ) throws {
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
        plannedSeconds: plannedSeconds, completedAt: nil, skippedAt: nil, createdAt: now)
      try item.insert(db)
    }
  }

  /// What finishing a focus block did to the underlying task. A daily's task
  /// survives the sitting — that is the whole point of modelling a daily as a
  /// contribution — so the caller needs to know which happened before it
  /// reports anything to the user.
  public enum FocusCompletionOutcome: Sendable, Equatable {
    case taskCompleted
    case contributionLogged(seconds: Int)
  }

  public struct FocusCompletion: Sendable, Equatable {
    public let session: FocusSession
    public let outcome: FocusCompletionOutcome
  }

  /// Finishes the current focus block, crediting `elapsedSeconds` of work.
  ///
  /// When the active task has a daily expected today the task stays open and
  /// the time lands on today's contribution instead. Otherwise the task is
  /// completed, which is what the queue's original behaviour was.
  @discardableResult
  public func completeActiveFocusTask(
    sessionId: String, elapsedSeconds: Int = 0, now: Date = .now, calendar: Calendar = .current
  ) throws -> FocusCompletion {
    try database.write { db in
      guard var session = try FocusSession.fetchOne(db, key: sessionId), let activeID = session.activeTaskId else {
        throw WorkspaceStoreError.noActiveFocusTask
      }
      var outcome = FocusCompletionOutcome.taskCompleted
      let daily = try Self.dueDaily(db, taskId: activeID, on: now, calendar: calendar)
      if let daily {
        let credited = max(0, elapsedSeconds)
        try Self.recordContribution(
          db, daily: daily, seconds: credited, complete: true, now: now, calendar: calendar)
        outcome = .contributionLogged(seconds: credited)
      } else if var task = try WorkspaceTask.fetchOne(db, key: activeID) {
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
      return FocusCompletion(session: session, outcome: outcome)
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

  private static func nonEmptyName(_ raw: String) throws -> String {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { throw WorkspaceStoreError.emptyName }
    return value
  }

  private static func normalizedStrings(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.compactMap { value in
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, seen.insert(trimmed.localizedLowercase).inserted else { return nil }
      return trimmed
    }
  }

  private static func decodeStringArray(_ json: String) -> [String] {
    guard let data = json.data(using: .utf8), let values = try? JSONDecoder().decode([String].self, from: data) else {
      return []
    }
    return normalizedStrings(values)
  }

  /// Internal rather than private so `WorkspaceStore+Import.swift` — the same
  /// type, split only for size — can reach it.
  static func nextOrder(
    _ db: Database, table: String, whereSQL: String, arguments: StatementArguments
  ) throws -> Int {
    let sql = "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM \(table) WHERE \(whereSQL)"
    return try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
  }

  private static func persistTaskOrder(_ tasks: [WorkspaceTask], db: Database, now: Date) throws {
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

  private static func taskDescendantIDs(_ db: Database, of taskID: String) throws -> Set<String> {
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

  private static func folderDescendantIDs(_ db: Database, of folderID: String) throws -> Set<String> {
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
