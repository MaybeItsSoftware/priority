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
  /// The Rust core's handle on the same file (core/src/workspace.rs): a
  /// connection of its own, on the same system SQLite as GRDB. What has moved
  /// into the core so far (docs/rust-core-migration.md) goes through it.
  let core: CoreWorkspace
  /// How far the writer's `data_version` has moved because of this store's
  /// own writes through `core`. See `coreWrite`.
  let ownCoreCommitLock = NSLock()
  var ownCoreCommitCount = 0

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
    self.core = try CoreWorkspace.open(path: databaseURL.path)
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

  /// Creates a folder after its siblings: the Rust core's `lists::create_folder`.
  public func createFolder(
    workspaceId: String,
    name: String,
    parentFolderId: String? = nil,
    now: Date = .now
  ) throws -> ListFolder {
    let created = try coreWrite {
      try core.createFolder(
        workspaceId: workspaceId, name: name, parentFolderId: parentFolderId, nowMs: now.coreMilliseconds)
    }
    return ListFolder(
      id: created.id, workspaceId: workspaceId, parentFolderId: parentFolderId,
      name: created.name, sortOrder: Int(created.sortOrder), createdAt: now, updatedAt: now)
  }

  /// Creates a list after its siblings: the Rust core's `lists::create_list`.
  public func createList(
    workspaceId: String,
    name: String,
    folderId: String? = nil,
    now: Date = .now
  ) throws -> TaskList {
    let created = try coreWrite {
      try core.createList(workspaceId: workspaceId, name: name, folderId: folderId, nowMs: now.coreMilliseconds)
    }
    return TaskList(
      id: created.id, workspaceId: workspaceId, folderId: folderId, name: created.name,
      colorHex: nil, sortOrder: Int(created.sortOrder), isArchived: false, createdAt: now, updatedAt: now)
  }

  public func task(id: String) throws -> WorkspaceTask? {
    try database.read { db in try WorkspaceTask.fetchOne(db, key: id) }
  }

  /// Renames a folder: the Rust core's `lists::rename_folder`.
  public func updateFolder(id: String, name: String, now: Date = .now) throws {
    try coreWrite { try core.renameFolder(id: id, name: name, nowMs: now.coreMilliseconds) }
  }

  /// Moves a folder into another or to the top: the Rust core's `lists::move_folder`.
  public func moveFolder(id: String, toParentFolderId parentFolderId: String?, now: Date = .now) throws {
    try coreWrite { try core.moveFolder(id: id, parentFolderId: parentFolderId, nowMs: now.coreMilliseconds) }
  }

  /// Deletes a folder as one undo step. Its lists move to the sidebar root
  /// (the schema's SET NULL) and folders inside it go with it. The write is
  /// the Rust core's (`lists::delete_folder`).
  public func deleteFolder(id: String) throws {
    try coreWrite { _ = try core.deleteFolder(id: id) }
  }

  /// Sets a list's name and colour: the Rust core's `lists::update_list`.
  public func updateList(id: String, name: String, colorHex: String?, now: Date = .now) throws {
    try coreWrite {
      try core.updateList(id: id, name: name, colourHex: colorHex, nowMs: now.coreMilliseconds)
    }
  }

  /// Renames a list and touches nothing else.
  ///
  /// Separate from `updateList` so that renaming from the sidebar cannot carry
  /// a stale colour along with it, and so undo offers "Rename List" rather
  /// than the settings sheet's broader "Edit List".
  /// Renames a list and nothing else: the Rust core's `lists::rename_list`.
  public func renameList(id: String, name: String, now: Date = .now) throws {
    try coreWrite { try core.renameList(id: id, name: name, nowMs: now.coreMilliseconds) }
  }

  /// Moves a list into a folder or to the top: the Rust core's `lists::move_list`.
  public func moveList(id: String, toFolderId folderId: String?, now: Date = .now) throws {
    try coreWrite { try core.moveList(id: id, folderId: folderId, nowMs: now.coreMilliseconds) }
  }

  /// Moves a list among its siblings: the Rust core's `lists::move_list_within_folder`.
  public func moveListWithinFolder(id: String, by offset: Int, now: Date = .now) throws {
    try coreWrite {
      try core.moveListWithinFolder(id: id, offset: Int32(clamping: offset), nowMs: now.coreMilliseconds)
    }
  }

  /// Puts `id` immediately before `targetID` among its siblings, moving it
  /// into `folderId` first when the drag crossed a folder boundary.
  ///
  /// `targetID` of nil means the end of that group, which is what a drop below
  /// the last row means. Reordering is absolute rather than a signed offset
  /// because a drag says where a thing landed, not how far it travelled.
  /// Drops a list before another in a folder: the Rust core's `lists::place_list`.
  public func placeList(
    id: String, before targetID: String?, inFolderId folderId: String?, now: Date = .now
  ) throws {
    try coreWrite {
      try core.placeList(id: id, beforeId: targetID, folderId: folderId, nowMs: now.coreMilliseconds)
    }
  }

  /// The same placement for folders, which nest, so the parent is checked for
  /// the cycle a folder dropped inside its own descendant would make.
  /// Drops a folder before another in a parent: the Rust core's `lists::place_folder`.
  public func placeFolder(
    id: String, before targetID: String?, inParentFolderId parentFolderId: String?, now: Date = .now
  ) throws {
    try coreWrite {
      try core.placeFolder(id: id, beforeId: targetID, parentFolderId: parentFolderId, nowMs: now.coreMilliseconds)
    }
  }

  /// Moves a folder among its siblings: the Rust core's `lists::move_folder_within_siblings`.
  public func moveFolderWithinSiblings(id: String, by offset: Int, now: Date = .now) throws {
    try coreWrite {
      try core.moveFolderWithinSiblings(id: id, offset: Int32(clamping: offset), nowMs: now.coreMilliseconds)
    }
  }

  /// Archives or restores a list; the Inbox stays. The Rust core's
  /// `lists::set_list_archived`.
  public func setListArchived(_ archived: Bool, id: String, now: Date = .now) throws {
    try coreWrite {
      try core.setListArchived(id: id, archived: archived, nowMs: now.coreMilliseconds)
    }
  }

  /// Deletes a list and its tasks as one undo step; the Inbox is permanent.
  /// The write is the Rust core's (`lists::delete_list`).
  public func deleteList(id: String) throws {
    try coreWrite { _ = try core.deleteList(id: id) }
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

  /// Creates a task, with whatever the add field read off its title, as one
  /// undo step: the Rust core's `tasks::create_task`.
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
    let new = NewTask(
      listId: listId, title: title, parentTaskId: parentTaskId, kind: kind.rawValue, notes: "",
      kanbanColumn: kanbanColumn, startAtMs: startAt?.coreMilliseconds, dueAtMs: dueAt?.coreMilliseconds,
      estimateSeconds: estimateSeconds.map(Int64.init), tags: tags, priority: priority.map(Int64.init),
      waitingOn: waitingOn, externalLinks: [], atTop: atTop, adjacentTaskId: adjacentTaskId, above: above)
    let id = try coreWrite { try core.createTask(task: new, nowMs: now.coreMilliseconds) }
    guard let task = try database.read({ db in try WorkspaceTask.fetchOne(db, key: id) }) else {
      throw WorkspaceStoreError.missingTask
    }
    return task
  }

  /// Opens, completes or cancels a task: the Rust core's `tasks::set_status`,
  /// which also writes a repeating task's next occurrence, stepped in the
  /// user's time zone, and ends the habits made from it.
  public func setStatus(_ status: TaskStatus, for taskId: String, now: Date = .now) throws {
    try coreWrite {
      try core.setStatus(
        taskId: taskId, status: status.rawValue, nowMs: now.coreMilliseconds,
        zone: TimeZone.current.identifier)
    }
  }

  /// Sets a task's title, notes, due time and estimate: the Rust core's
  /// `editor::update_task`. A due time replaces a due date in its planning.
  public func updateTask(
    id: String,
    title: String,
    notes: String,
    dueAt: Date?,
    estimateSeconds: Int?,
    now: Date = .now
  ) throws {
    try coreWrite {
      try core.updateTask(
        id: id, title: title, notes: notes, dueAtMs: dueAt?.coreMilliseconds,
        estimateSeconds: estimateSeconds.map { Int64($0) }, nowMs: now.coreMilliseconds, zone: TimeZone.current.identifier)
    }
  }

  public func taskEditorMetadata(for taskId: String) throws -> TaskEditorMetadata {
    try database.read { db in try Self.taskEditorSnapshot(db, taskId: taskId).metadata }
  }

  /// Sets a task's priority, tags, links and repeat: the Rust core's
  /// `editor::update_editor_metadata`.
  public func updateTaskEditorMetadata(
    taskId: String, metadata: TaskEditorMetadata, now: Date = .now
  ) throws {
    try coreWrite {
      try core.updateEditorMetadata(taskId: taskId, metadata: metadata.core, nowMs: now.coreMilliseconds)
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
  /// Puts tasks in a board column as one step: the Rust core's
  /// `tasks::set_kanban_column`.
  public func setKanbanColumn(_ column: String?, for taskIDs: [String], now: Date = .now) throws {
    guard !taskIDs.isEmpty else { return }
    try coreWrite {
      try core.setKanbanColumn(taskIds: taskIDs, column: column, nowMs: now.coreMilliseconds)
    }
  }

  public func matrixPosition(for taskId: String) throws -> TaskMatrixPosition {
    try database.read { db in
      let metadata = try TaskMetadata.fetchOne(db, key: taskId)
      return TaskMatrixPosition(urgency: metadata?.matrixUrgency, importance: metadata?.matrixImportance)
    }
  }

  /// Places a task on the priority matrix: the Rust core's `tasks::set_matrix_position`.
  public func setMatrixPosition(
    _ position: TaskMatrixPosition,
    for taskId: String,
    now: Date = .now
  ) throws {
    try coreWrite {
      try core.setMatrixPosition(
        id: taskId, urgency: position.urgency.map(Int64.init), importance: position.importance.map(Int64.init),
        nowMs: now.coreMilliseconds)
    }
  }

  /// Moves a task and its complete subtree. A destination parent must belong to
  /// the destination list and may not be the task itself or one of its descendants.
  /// Moves a task and its subtree: the Rust core's `tasks::move_task`.
  public func moveTask(
    id: String, toListId listId: String, parentTaskId: String? = nil,
    toVisibleRoot: Bool = false, now: Date = .now
  ) throws {
    try coreWrite {
      try core.moveTask(
        id: id, listId: listId, parentTaskId: parentTaskId, toVisibleRoot: toVisibleRoot, nowMs: now.coreMilliseconds)
    }
  }

  /// Moves a task among its siblings: the Rust core's `tasks::move_task_within_siblings`.
  public func moveTaskWithinSiblings(id: String, by offset: Int, now: Date = .now) throws {
    try coreWrite {
      try core.moveTaskWithinSiblings(id: id, offset: Int32(clamping: offset), nowMs: now.coreMilliseconds)
    }
  }

  /// Places a newly captured task at the top of its project/list. The Today
  /// queue uses this same persistent order, so the first card is first live.
  /// Moves a task to the top of its siblings: the Rust core's `tasks::move_task_to_start`.
  public func moveTaskToStart(id: String, now: Date = .now) throws {
    try coreWrite { try core.moveTaskToStart(id: id, nowMs: now.coreMilliseconds) }
  }

  /// Reorders a card before another card without changing either task's real
  /// list or project parent. Cross-project drops remain a list-move operation.
  /// Drops a task before a sibling: the Rust core's `tasks::move_task_before`.
  public func moveTaskBefore(id: String, targetId: String, kanbanColumn: String? = nil, now: Date = .now) throws {
    try coreWrite {
      try core.moveTaskBefore(id: id, targetId: targetId, kanbanColumn: kanbanColumn, nowMs: now.coreMilliseconds)
    }
  }

  /// Makes the selected task a child of its immediately preceding sibling.
  /// Indents a task under the sibling above: the Rust core's `tasks::indent_task`.
  public func indentTask(id: String, now: Date = .now) throws {
    try coreWrite { try core.indentTask(id: id, nowMs: now.coreMilliseconds) }
  }

  /// Promotes a task one level, immediately after its former parent.
  /// Outdents a task to follow its parent: the Rust core's `tasks::outdent_task`.
  public func outdentTask(id: String, now: Date = .now) throws {
    try coreWrite { try core.outdentTask(id: id, nowMs: now.coreMilliseconds) }
  }

  /// Deletes a task and its subtree as one undo step. The write is the Rust
  /// core's (`tasks::delete_task`), shared with Android and the CLI.
  public func deleteTask(id: String) throws {
    try coreWrite { _ = try core.deleteTask(id: id) }
  }

  /// Runs a call into the Rust core, turning the failures callers react to
  /// into the store's own errors, so the screens that match on
  /// `WorkspaceStoreError` see the same cases whichever side made the write.
  static func mappingCoreErrors<T>(_ call: () throws -> T) throws -> T {
    do {
      return try call()
    } catch {
      switch error.coreFailure {
      case .missingTask: throw WorkspaceStoreError.missingTask
      case .missingDaily: throw WorkspaceStoreError.missingDaily
      case .missingList: throw WorkspaceStoreError.missingList
      case .missingFolder: throw WorkspaceStoreError.missingFolder
      case .systemListIsPermanent: throw WorkspaceStoreError.systemListIsPermanent
      case .emptyName: throw WorkspaceStoreError.emptyName
      case .invalidFolderMove: throw WorkspaceStoreError.invalidFolderMove
      case .invalidCondition: throw TaskPlanningError.invalidCondition
      case .invalidSchedule: throw TaskPlanningError.invalidSchedule
      case .invalidMinimum: throw TaskPlanningError.invalidMinimum
      case .estimateRequired: throw TaskPlanningError.estimateRequired
      case .invalidDate: throw TaskPlanningError.invalidDate
      case .editorConflict: throw TaskEditorError.conflictingChanges
      case .invalidTaskMove: throw WorkspaceStoreError.invalidTaskMove
      case .noJournal, .other, nil: throw error
      }
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

extension Date {
  /// This moment as the Rust core takes it: whole milliseconds since 1970,
  /// rounded to the nearest. A date GRDB read back from `...20.123` can be a
  /// hair under it, and truncating would make it `...20.122`, so a value
  /// read, sent to the core and compared there would no longer match.
  var coreMilliseconds: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
}
