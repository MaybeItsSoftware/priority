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
    guard !scoped.isEmpty else { return [] }
    // Picked in the Rust core (`board::actionable_tasks`), by the rule
    // `WorkspaceListTree.actionableTasks(visibleRootTaskId:)` states, so
    // only the cards cross rather than every task in every list.
    return try PackedTaskRows.decode(
      Self.mappingCoreErrors { try core.actionableTasksPacked(listIds: scoped.map(\.id)) })
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
    let core = columns.map(\.core)
    try coreWrite {
      try self.core.setBoardColumns(
        key: key, columns: core, movingTaskIds: movingTaskIDs, toColumn: toColumn, label: label,
        nowMs: Date.now.coreMilliseconds)
    }
  }

  /// The columns a board draws and where each task stands on it: the Rust
  /// core's `board_columns::board_columns`. `listIDs` are the lists the
  /// board shows, for the rule columns and the columns its cards use.
  public func boardColumns(key: String, listIDs: [String], now: Date = .now) throws -> WorkspaceBoardColumns {
    let read = try Self.mappingCoreErrors {
      try core.boardColumns(
        key: key, listIds: listIDs, nowMs: now.coreMilliseconds, zone: TimeZone.current.identifier)
    }
    return WorkspaceBoardColumns(read)
  }

  /// Deletes a column, moving the tasks filed in it to `toColumn`, as one
  /// "Delete Column" step. A rule column, Today and Waiting on move nothing.
  public func deleteBoardColumn(key: String, listIDs: [String], columnID: String, toColumn: String?) throws {
    try coreWrite {
      try core.deleteBoardColumn(
        key: key, listIds: listIDs, columnId: columnID, toColumn: toColumn, nowMs: Date.now.coreMilliseconds)
    }
  }

  /// Drops a board's own columns, so it follows its list's or the default.
  public func resetBoardColumns(key: String) throws {
    try coreWrite { try core.resetBoardColumns(key: key) }
  }

  /// Makes a board's columns the default, and has the board follow it.
  public func makeDefaultBoardColumns(key: String) throws {
    try coreWrite { try core.makeDefaultBoardColumns(key: key) }
  }

  /// Puts tasks in a column. Into a rule column the first task is edited to
  /// match its rules; a move the rules would undo is refused
  /// (`WorkspaceStoreError.columnRefused`).
  public func moveToBoardColumn(key: String, taskIDs: [String], columnID: String, now: Date = .now) throws {
    guard !taskIDs.isEmpty else { return }
    try coreWrite {
      try core.moveToBoardColumn(
        key: key, taskIds: taskIDs, columnId: columnID, nowMs: now.coreMilliseconds,
        zone: TimeZone.current.identifier)
    }
  }
}

/// A board's columns as the core resolves them. See `board_columns.rs`.
public struct WorkspaceBoardColumns: Equatable, Sendable {
  /// Where the layout came from.
  public enum Source: String, Sendable {
    /// The board's own.
    case own
    /// An entered card's board, following its list's.
    case list
    /// The workspace's default columns.
    case `default`
    /// The stock five, nobody having set a default.
    case builtin
  }

  public static let defaultKey = "default"

  public var key: String
  /// The layout as an edit saves it, hidden columns included.
  public var layout: [WorkspaceKanbanColumn]
  public var source: Source
  /// What the board draws, left to right.
  public var columns: [WorkspaceKanbanColumn]
  /// Columns left of an entered card's own: a child is not at an earlier
  /// stage than its parent.
  public var hiddenColumnIDs: Set<String>
  /// The entered card's column, where children filed further left stand.
  public var floorColumnID: String?
  /// Each task drawn somewhere other than where its filed column alone
  /// would put it: by a rule column, or clamped to the floor.
  public var placements: [String: String]

  public init(
    key: String, layout: [WorkspaceKanbanColumn], source: Source = .builtin,
    columns: [WorkspaceKanbanColumn]? = nil, hiddenColumnIDs: Set<String> = [], floorColumnID: String? = nil,
    placements: [String: String] = [:]
  ) {
    self.key = key
    self.layout = layout
    self.source = source
    self.columns = columns ?? layout
    self.hiddenColumnIDs = hiddenColumnIDs
    self.floorColumnID = floorColumnID
    self.placements = placements
  }

  init(_ read: BoardColumns) {
    self.init(
      key: read.key, layout: read.layout.map(WorkspaceKanbanColumn.init),
      source: Source(rawValue: read.source) ?? .own,
      columns: read.columns.map(WorkspaceKanbanColumn.init), hiddenColumnIDs: Set(read.hiddenColumnIds),
      floorColumnID: read.floorColumnId,
      placements: Dictionary(
        read.placements.map { ($0.taskId, $0.columnId) }, uniquingKeysWith: { first, _ in first }))
  }

  /// The column a task is drawn in: its placement, else its filed column
  /// when the board draws it, else the first column.
  public func columnID(forTaskID id: String, filed: String?) -> String? {
    if let placed = placements[id] { return placed }
    let wanted = filed ?? WorkspaceKanbanColumn.blitzitDefaults[0].id
    if columns.contains(where: { $0.id == wanted }) { return wanted }
    return columns.first?.id
  }
}

extension WorkspaceKanbanColumn {
  init(_ core: BoardColumn) {
    self.init(id: core.id, title: core.title, rules: core.rules.map(WorkspaceFilterDefinition.init))
  }

  var core: BoardColumn { BoardColumn(id: id, title: title, rules: rules?.core) }
}
