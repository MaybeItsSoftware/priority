import Foundation
import GRDB

extension WorkspaceStore {
  /// Dropping an item onto a folder or the top level makes it a standalone list, retaining
  /// its identity and descendants. Conversion and relocation are one undo step.
  @discardableResult
  public func moveTaskToFolder(id: String, folderId: String?, now: Date = .now) throws -> TaskList {
    try journalledWrite(folderId == nil ? "Move Item to Top Level" : "Move Item to Folder") { db in
      guard var task = try WorkspaceTask.fetchOne(db, key: id),
        let source = try TaskList.fetchOne(db, key: task.listId) else { throw WorkspaceStoreError.missingTask }
      if let folderId {
        guard let folder = try ListFolder.fetchOne(db, key: folderId), folder.workspaceId == source.workspaceId else {
          throw WorkspaceStoreError.missingFolder
        }
      }
      // Do not extract a transport wrapper and leave a broken source list.
      guard source.visibleRootTaskId != id else { throw WorkspaceStoreError.invalidTaskMove }
      let destination = TaskList(id: UUID().uuidString, workspaceId: source.workspaceId, folderId: folderId,
          name: task.title, colorHex: source.colorHex,
          sortOrder: try Self.nextOrder(db, table: "task_lists", whereSQL: "workspaceId = ? AND folderId IS ?", arguments: [source.workspaceId, folderId]),
          isArchived: task.isList && task.archivedAt != nil,
          visibleRootTaskId: task.id,
          completedAt: task.isList && task.status != .open ? now : nil,
          createdAt: now, updatedAt: now)
      try destination.insert(db)
      let parentID: String? = nil
      let ids = try Self.taskDescendantIDs(db, of: id).union([id])
      let values: [Any] = [destination.id, now] + ids.sorted()
      guard let arguments = StatementArguments(values) else { throw WorkspaceStoreError.invalidTaskMove }
      try db.execute(sql: "UPDATE tasks SET listId = ?, updatedAt = ? WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))",
        arguments: arguments)
      task.listId = destination.id
      task.parentTaskId = parentID
      task.sortOrder = try Self.nextOrder(db, table: "tasks", whereSQL: "listId = ? AND parentTaskId IS ?", arguments: [destination.id, parentID])
      task.itemKind = .list
      task.isPromoted = nil
      task.archivedAt = nil
      task.status = .open
      task.updatedAt = now
      try task.update(db)
      return destination
    }
  }

  /// A standalone list becomes one task in Inbox, keeping all existing child
  /// identities, metadata and hierarchy. The whole operation is one undo step.
  @discardableResult
  public func convertListToTask(id: String, now: Date = .now) throws -> WorkspaceTask {
    try journalledWrite("Convert List to Task") { db in
      guard let list = try TaskList.fetchOne(db, key: id) else { throw WorkspaceStoreError.missingList }
      guard !list.isSystemList else { throw WorkspaceStoreError.systemListIsPermanent }
      guard let inbox = try TaskList.filter(Column("workspaceId") == list.workspaceId
        && Column("systemRole") == TaskListRole.inbox.rawValue).fetchOne(db) else {
        throw WorkspaceStoreError.missingList
      }
      return try Self.relocateList(db, list: list, destination: inbox, parentTaskId: nil, kind: .task, now: now)
    }
  }

  /// Dragging a standalone list into another list preserves the full contents
  /// as a nested list, rather than merging away the source list's identity.
  @discardableResult
  public func nestList(id: String, inListId: String, parentTaskId: String? = nil, now: Date = .now) throws -> WorkspaceTask {
    try journalledWrite("Move List into List") { db in
      guard let list = try TaskList.fetchOne(db, key: id),
        let destination = try TaskList.fetchOne(db, key: inListId) else { throw WorkspaceStoreError.missingList }
      guard !list.isSystemList else { throw WorkspaceStoreError.systemListIsPermanent }
      guard id != inListId, list.workspaceId == destination.workspaceId else { throw WorkspaceStoreError.invalidTaskMove }
      let parentID = try parentTaskId ?? destination.visibleRootTaskId.flatMap { rootID in
        // Only use a transport wrapper that still represents the visible root.
        let roots = try WorkspaceTask.filter(Column("listId") == inListId && Column("parentTaskId") == nil).fetchAll(db)
        return roots.count == 1 && roots.first?.id == rootID ? rootID : nil
      }
      if let parentID {
        guard let parent = try WorkspaceTask.fetchOne(db, key: parentID), parent.listId == inListId,
          parent.isList || parent.id == destination.visibleRootTaskId else { throw WorkspaceStoreError.invalidTaskMove }
      }
      return try Self.relocateList(db, list: list, destination: destination, parentTaskId: parentID, kind: .list, now: now)
    }
  }

  private static func relocateList(_ db: Database, list: TaskList, destination: TaskList,
                                   parentTaskId: String?, kind: WorkspaceItemKind, now: Date) throws -> WorkspaceTask {
      let tasks = try WorkspaceTask.filter(Column("listId") == list.id).fetchAll(db)
      let wrapper = tasks.first { $0.id == list.visibleRootTaskId && $0.parentTaskId == nil }
      var root = wrapper ?? WorkspaceTask(id: UUID().uuidString, listId: destination.id, parentTaskId: parentTaskId,
        title: list.name, notes: "", status: .open, sortOrder: 0, dueAt: nil, estimateSeconds: nil,
        createdAt: now, updatedAt: now)
      root.listId = destination.id
      root.parentTaskId = parentTaskId
      root.title = list.name
      root.itemKind = kind
      root.isPromoted = nil
      root.archivedAt = nil
      root.status = list.completedAt == nil ? .open : .completed
      root.completedAt = list.completedAt
      root.sortOrder = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM tasks WHERE listId = ? AND parentTaskId IS ?", arguments: [destination.id, parentTaskId]) ?? 0
      root.updatedAt = now
      if wrapper == nil { try root.insert(db) }
      for var task in tasks where task.id != root.id {
        task.listId = destination.id
        if task.parentTaskId == nil { task.parentTaskId = root.id }
        task.updatedAt = now
        try task.update(db)
      }
      if wrapper != nil { try root.update(db) }
      try TaskList.deleteOne(db, key: list.id)
      return root
  }

  public func setItemKind(_ kind: WorkspaceItemKind, for id: String, now: Date = .now) throws {
    try journalledWrite(kind == .list ? "Convert to List" : "Convert to Task") { db in
      guard var task = try WorkspaceTask.fetchOne(db, key: id) else { throw WorkspaceStoreError.missingTask }
      guard (task.itemKind ?? .task) != kind else { return }
      // A transport wrapper is already represented by its top-level list.
      guard try TaskList.filter(Column("visibleRootTaskId") == id).fetchCount(db) == 0 else {
        throw WorkspaceStoreError.invalidTaskMove
      }
      guard try FocusSession.filter(Column("activeTaskId") == id
        && Column("phase") != FocusSessionPhase.finished.rawValue).fetchCount(db) == 0 else {
        throw WorkspaceStoreError.invalidTaskMove
      }
      task.itemKind = kind
      if kind == .task { task.isPromoted = nil; task.archivedAt = nil }
      task.updatedAt = now
      try task.update(db)
    }
  }

  public func setNestedListPromoted(_ promoted: Bool, id: String, now: Date = .now) throws {
    try journalledWrite(promoted ? "Promote List" : "Unpin List") { db in
      guard var task = try WorkspaceTask.fetchOne(db, key: id), task.isList else {
        throw WorkspaceStoreError.missingList
      }
      guard (task.isPromoted == true) != promoted else { return }
      task.isPromoted = promoted
      task.updatedAt = now
      try task.update(db)
    }
  }

  public func setNestedListArchived(_ archived: Bool, id: String, now: Date = .now) throws {
    try journalledWrite(archived ? "Archive Nested List" : "Restore Nested List") { db in
      guard var task = try WorkspaceTask.fetchOne(db, key: id), task.isList else {
        throw WorkspaceStoreError.missingList
      }
      guard (task.archivedAt != nil) != archived else { return }
      task.archivedAt = archived ? now : nil
      task.updatedAt = now
      try task.update(db)
    }
  }

  public func setListCompleted(_ completed: Bool, id: String, now: Date = .now) throws {
    try journalledWrite(completed ? "Complete List" : "Reopen List") { db in
      guard var list = try TaskList.fetchOne(db, key: id) else { throw WorkspaceStoreError.missingList }
      guard !list.isSystemList else { throw WorkspaceStoreError.systemListIsPermanent }
      guard (list.completedAt != nil) != completed else { return }
      list.completedAt = completed ? now : nil
      list.updatedAt = now
      try list.update(db)
    }
  }

  /// Closed/archived containers suppress descendants without altering their status.
  static func inactiveContainerItems(_ tasks: [WorkspaceTask]) -> Set<String> {
    let children = Dictionary(grouping: tasks, by: \.parentTaskId)
    var result = Set<String>()
    func suppress(_ task: WorkspaceTask) {
      guard result.insert(task.id).inserted else { return }
      for child in children[task.id, default: []] { suppress(child) }
    }
    for task in tasks where task.isList && (task.archivedAt != nil || task.status != .open) {
      suppress(task)
    }
    return result
  }

  public func actionableTasks(in workspaceId: String) throws -> [WorkspaceTask] {
    try lists(in: workspaceId).filter { $0.completedAt == nil }.flatMap { list in
      let items = try outline(in: list.id).map(\.task)
      let inactive = Self.inactiveContainerItems(items)
      return items.filter {
        !$0.isList && $0.id != list.visibleRootTaskId && !inactive.contains($0.id)
          && $0.status == .open
      }
    }
  }

  public func visibleOutline(in listId: String, parentTaskId: String? = nil) throws -> [TaskOutlineItem] {
    let items = try outline(in: listId, parentTaskId: parentTaskId)
    var archivedDepth: Int?
    return items.filter { item in
      if let depth = archivedDepth, item.depth <= depth { archivedDepth = nil }
      if archivedDepth != nil { return false }
      if item.task.isList && item.task.archivedAt != nil { archivedDepth = item.depth; return false }
      return true
    }
  }

  static func validateActionableTask(_ db: Database, id: String) throws {
    guard let task = try WorkspaceTask.fetchOne(db, key: id) else { throw WorkspaceStoreError.missingTask }
    guard !task.isList,
      let list = try TaskList.fetchOne(db, key: task.listId), !list.isArchived, list.completedAt == nil,
      list.visibleRootTaskId != id,
      !inactiveContainerItems(try WorkspaceTask.filter(Column("listId") == task.listId).fetchAll(db)).contains(id)
    else { throw WorkspaceStoreError.invalidTaskMove }
  }
}


extension WorkspaceStore {
  /// Import the old preferences as a baseline, without creating undo steps.
  public func kanbanBoardConfigurations(legacy: [String: Data], currentKey: String) throws -> [String: Data] {
    try database.write { db in
      var baseline = legacy
      if baseline[currentKey] == nil {
        baseline[currentKey] = try JSONEncoder().encode(WorkspaceKanbanColumn.blitzitDefaults)
      }
      for (key, data) in baseline {
        guard let columns = try? JSONDecoder().decode([WorkspaceKanbanColumn].self, from: data),
          !columns.isEmpty, let json = String(data: data, encoding: .utf8) else { continue }
        try db.execute(sql: "INSERT OR IGNORE INTO kanban_boards(id, columnsJSON) VALUES (?, ?)", arguments: [key, json])
      }
      return Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, columnsJSON FROM kanban_boards").map { row in
        let key: String = row["id"]
        let json: String = row["columnsJSON"]
        return (key, Data(json.utf8))
      })
    }
  }

  /// A removed column and the cards moved out of it form one undo step.
  public func setKanbanBoardColumns(
    _ columns: [WorkspaceKanbanColumn], for key: String,
    movingTaskIDs: [String] = [], toColumn: String? = nil, label: String = "Edit Board"
  ) throws {
    guard !columns.isEmpty else { return }
    let json = String(decoding: try JSONEncoder().encode(columns), as: UTF8.self)
    try journalledWrite(label) { db in
      for id in Set(movingTaskIDs) {
        guard try WorkspaceTask.fetchOne(db, key: id) != nil else { throw WorkspaceStoreError.missingTask }
        try db.execute(sql: """
          INSERT INTO task_metadata(taskId, tagsJSON, externalLinksJSON, kanbanColumn, updatedAt)
          VALUES (?, '[]', '[]', ?, ?)
          ON CONFLICT(taskId) DO UPDATE SET kanbanColumn = excluded.kanbanColumn, updatedAt = excluded.updatedAt
          """, arguments: [id, toColumn, Date.now])
      }
      try db.execute(sql: """
        INSERT INTO kanban_boards(id, columnsJSON) VALUES (?, ?)
        ON CONFLICT(id) DO UPDATE SET columnsJSON = excluded.columnsJSON
        WHERE columnsJSON != excluded.columnsJSON
        """, arguments: [key, json])
    }
  }
}
