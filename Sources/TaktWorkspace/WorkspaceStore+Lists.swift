import Foundation
import TaktRustCore

extension WorkspaceStore {
  /// Dropping an item onto a folder or the top level makes it a standalone list, retaining
  /// its identity and descendants. Conversion and relocation are one undo step.
  @discardableResult
  public func moveTaskToFolder(id: String, folderId: String?, now: Date = .now) throws -> TaskList {
    // The Rust core's `conversions::move_task_to_folder`.
    let listID = try coreWrite { try core.moveTaskToFolder(id: id, folderId: folderId, nowMs: now.coreMilliseconds) }
    guard let list = try Self.mappingCoreErrors({ try core.list(id: listID) }).map(TaskList.init) else {
      throw WorkspaceStoreError.missingList
    }
    return list
  }

  /// A standalone list becomes one task in Inbox, keeping all existing child
  /// identities, metadata and hierarchy. The whole operation is one undo step.
  @discardableResult
  public func convertListToTask(id: String, now: Date = .now) throws -> WorkspaceTask {
    // The Rust core's `conversions::convert_list_to_task`.
    let taskID = try coreWrite { try core.convertListToTask(id: id, nowMs: now.coreMilliseconds) }
    return try fetchTask(taskID)
  }

  /// Dragging a standalone list into another list preserves the full contents
  /// as a nested list, rather than merging away the source list's identity.
  @discardableResult
  public func nestList(id: String, inListId: String, parentTaskId: String? = nil, now: Date = .now) throws -> WorkspaceTask {
    // The Rust core's `conversions::nest_list`.
    let taskID = try coreWrite {
      try core.nestList(id: id, intoListId: inListId, parentTaskId: parentTaskId, nowMs: now.coreMilliseconds)
    }
    return try fetchTask(taskID)
  }

  private func fetchTask(_ id: String) throws -> WorkspaceTask {
    guard let task = try task(id: id) else {
      throw WorkspaceStoreError.missingTask
    }
    return task
  }

  public func setItemKind(_ kind: WorkspaceItemKind, for id: String, now: Date = .now) throws {
    try coreWrite { try core.setItemKind(id: id, kind: kind.rawValue, nowMs: now.coreMilliseconds) }
  }

  public func setNestedListPromoted(_ promoted: Bool, id: String, now: Date = .now) throws {
    try coreWrite { try core.setNestedListPromoted(id: id, promoted: promoted, nowMs: now.coreMilliseconds) }
  }

  public func setNestedListArchived(_ archived: Bool, id: String, now: Date = .now) throws {
    try coreWrite { try core.setNestedListArchived(id: id, archived: archived, nowMs: now.coreMilliseconds) }
  }

  public func setListCompleted(_ completed: Bool, id: String, now: Date = .now) throws {
    try coreWrite { try core.setListCompleted(id: id, completed: completed, nowMs: now.coreMilliseconds) }
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

  /// - Parameter listIds: when given, only these lists contribute, in the
  ///   order they are listed. A folder scope passes the folder's lists here,
  ///   so the combined view is the same query Everything runs, narrowed.
  public func actionableTasks(
    in workspaceId: String, limitedTo listIds: [String]? = nil
  ) throws -> [WorkspaceTask] {
    let all = try lists(in: workspaceId).filter { $0.completedAt == nil }
    let scoped: [TaskList]
    if let listIds {
      let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      scoped = listIds.compactMap { byID[$0] }
    } else {
      scoped = all
    }
    let trees = try listTrees(in: scoped.map(\.id))
    return scoped.flatMap { list in
      trees[list.id]?.actionableTasks(visibleRootTaskId: list.visibleRootTaskId) ?? []
    }
  }

  public func visibleOutline(in listId: String, parentTaskId: String? = nil) throws -> [TaskOutlineItem] {
    try listTree(in: listId).visibleOutline(under: parentTaskId)
  }
}

extension WorkspaceStore {
  /// Import the old preferences as a baseline, without creating undo steps.
  public func kanbanBoardConfigurations(legacy: [String: Data], currentKey: String) throws -> [String: Data] {
    // The Rust core's `imports::kanban_board_baseline`.
    let seeds = legacy.compactMap { key, data in
      String(data: data, encoding: .utf8).map { BoardBaseline(key: key, columnsJson: $0) }
    }
    let boards = try coreWrite { try core.kanbanBoardBaseline(legacy: seeds, currentKey: currentKey) }
    return Dictionary(boards.map { ($0.key, Data($0.columnsJson.utf8)) }, uniquingKeysWith: { first, _ in first })
  }

  /// A removed column and the cards moved out of it form one undo step.
  public func setKanbanBoardColumns(
    _ columns: [WorkspaceKanbanColumn], for key: String,
    movingTaskIDs: [String] = [], toColumn: String? = nil, label: String = "Edit Board"
  ) throws {
    // The Rust core's `conversions::set_board_columns`.
    let core = columns.map { BoardColumn(id: $0.id, title: $0.title) }
    try coreWrite {
      try self.core.setBoardColumns(
        key: key, columns: core, movingTaskIds: movingTaskIDs, toColumn: toColumn, label: label,
        nowMs: Date.now.coreMilliseconds)
    }
  }
}
