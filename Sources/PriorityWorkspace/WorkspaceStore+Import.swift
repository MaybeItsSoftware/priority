import Foundation
import GRDB

/// Bringing work in from somewhere else. Split from `WorkspaceStore.swift` —
/// the same type — because importing is a distinct job from editing, with its
/// own rule: running it twice must not produce two copies of anything.
extension WorkspaceStore {
  /// Copies tasks from an outside service into the workspace, and can be run
  /// again safely.
  ///
  /// A seed whose `(sourceSystem, sourceId)` is already present updates the
  /// task that is there rather than adding a second copy — and updates only
  /// its *content*. Where the task sits locally, which list it was moved to,
  /// and what it was reordered under are the user's decisions about their own
  /// workspace, so a re-import leaves them alone.
  ///
  /// Broken source parent links become roots instead of losing the task, and
  /// duplicate source IDs within one run are rejected.
  @discardableResult
  public func importTasks(
    workspaceId: String,
    listName: String,
    sourceSystem: String,
    seeds: [ImportedTaskSeed],
    now: Date = .now
  ) throws -> TaskImportOutcome? {
    guard !seeds.isEmpty else { return nil }
    guard Set(seeds.map(\.sourceId)).count == seeds.count else {
      throw WorkspaceStoreError.duplicateLegacySourceID
    }
    return try database.write { db in
      let existing = try Self.tasksBySourceID(db, workspaceId: workspaceId, sourceSystem: sourceSystem,
        sourceIDs: seeds.map(\.sourceId))

      // A previous run's list is the destination, so re-importing merges into
      // the list the user has been working in rather than beside it.
      let list: TaskList
      let createdList: Bool
      if let home = try Self.importDestinationList(db, existing: existing) {
        list = home
        createdList = false
      } else {
        let listOrder = try Self.nextOrder(
          db, table: TaskList.databaseTableName, whereSQL: "workspaceId = ? AND folderId IS ?",
          arguments: [workspaceId, nil])
        list = TaskList(
          id: UUID().uuidString, workspaceId: workspaceId, folderId: nil, name: listName,
          colorHex: nil, sortOrder: listOrder, isArchived: false, createdAt: now, updatedAt: now)
        try list.insert(db)
        createdList = true
      }

      var localIDBySourceID = existing.mapValues(\.id)
      for seed in seeds where localIDBySourceID[seed.sourceId] == nil {
        localIDBySourceID[seed.sourceId] = UUID().uuidString
      }

      let sourceIDs = Set(seeds.map(\.sourceId))
      var settledSourceIDs = Set<String>()
      var inserted: [String] = []
      var updated: [String] = []
      var remaining = seeds
      while !remaining.isEmpty {
        let nextIndex = remaining.firstIndex { seed in
          guard let parent = seed.parentSourceId else { return true }
          return !sourceIDs.contains(parent) || settledSourceIDs.contains(parent)
        }
        // A cyclic source hierarchy cannot be represented with foreign keys.
        // Keep every task by promoting one cycle member to a local root.
        let seed = remaining.remove(at: nextIndex ?? 0)
        let localID = localIDBySourceID[seed.sourceId]!

        if var task = existing[seed.sourceId] {
          task.title = seed.title
          task.notes = seed.notes
          task.status = seed.status
          task.updatedAt = now
          try task.update(db)
          updated.append(localID)
        } else {
          let parent = nextIndex == nil ? nil : seed.parentSourceId.flatMap { localIDBySourceID[$0] }
          let task = WorkspaceTask(
            id: localID, listId: list.id, parentTaskId: parent,
            title: seed.title, notes: seed.notes, status: seed.status, sortOrder: seed.sortOrder,
            dueAt: nil, estimateSeconds: nil, sourceSystem: sourceSystem, sourceId: seed.sourceId,
            createdAt: now, updatedAt: now)
          try task.insert(db)
          inserted.append(localID)
        }
        settledSourceIDs.insert(seed.sourceId)
      }
      if createdList { try Self.registerVisibleRoot(db, for: list) }
      return TaskImportOutcome(
        list: try TaskList.fetchOne(db, key: list.id)!,
        insertedTaskIDs: inserted, updatedTaskIDs: updated, createdList: createdList)
    }
  }

  private static func tasksBySourceID(
    _ db: Database, workspaceId: String, sourceSystem: String, sourceIDs: [String]
  ) throws -> [String: WorkspaceTask] {
    var found: [String: WorkspaceTask] = [:]
    // Chunked because SQLite caps how many parameters one statement may bind,
    // and an import is exactly the case that reaches the cap.
    for chunk in stride(from: 0, to: sourceIDs.count, by: 400).map({
      Array(sourceIDs[$0..<min($0 + 400, sourceIDs.count)])
    }) {
      let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
      let values: [any DatabaseValueConvertible] = [workspaceId, sourceSystem] + chunk
      let tasks = try WorkspaceTask.fetchAll(
        db,
        sql: """
          SELECT tasks.* FROM tasks
          JOIN task_lists ON task_lists.id = tasks.listId
          WHERE task_lists.workspaceId = ? AND tasks.sourceSystem = ? AND tasks.sourceId IN (\(placeholders))
          """,
        arguments: StatementArguments(values))
      for task in tasks { found[task.sourceId!] = task }
    }
    return found
  }

  /// The list most of a previous run's tasks still live in. "Most" rather than
  /// "the first" so moving one task out of an imported list does not send the
  /// next import somewhere else.
  private static func importDestinationList(
    _ db: Database, existing: [String: WorkspaceTask]
  ) throws -> TaskList? {
    guard !existing.isEmpty else { return nil }
    let counts = existing.values.reduce(into: [String: Int]()) { $0[$1.listId, default: 0] += 1 }
    guard let listID = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key else { return nil }
    return try TaskList.fetchOne(db, key: listID)
  }
}
