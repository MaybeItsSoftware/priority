import Foundation
import GRDB
import TaktCore

/// What a card shows about a task that is waiting, or that chases one.
public struct TaskWaitingDetails: Sendable, Equatable {
  public var waitingOn: String?
  public var followUpAt: Date?
  /// On a follow-up task: the waiting task it chases.
  public var followUpOfTaskId: String?

  public init(waitingOn: String? = nil, followUpAt: Date? = nil, followUpOfTaskId: String? = nil) {
    self.waitingOn = waitingOn
    self.followUpAt = followUpAt
    self.followUpOfTaskId = followUpOfTaskId
  }
}

/// Waiting on: a tag naming who or what a task waits on, a time to chase it,
/// and the follow-up task that lands in Today at that time if the task is
/// still waiting. `WaitingFollowUp` in TaktCore decides; this file applies it.
extension WorkspaceStore {

  // MARK: - Reading

  /// Every task with a waiting tag, a follow-up time, or a source it chases.
  /// A small set, read whole so a card's chip is a dictionary lookup.
  public func waitingDetails() throws -> [String: TaskWaitingDetails] {
    try database.read { db in
      let rows = try Row.fetchAll(db, sql: """
        SELECT taskId, waitingOn, waitingFollowUpAt, followUpOfTaskId FROM task_metadata
        WHERE waitingOn IS NOT NULL OR waitingFollowUpAt IS NOT NULL OR followUpOfTaskId IS NOT NULL
        """)
      var details: [String: TaskWaitingDetails] = [:]
      for row in rows {
        details[row["taskId"]] = TaskWaitingDetails(
          waitingOn: row["waitingOn"], followUpAt: row["waitingFollowUpAt"],
          followUpOfTaskId: row["followUpOfTaskId"])
      }
      return details
    }
  }

  // MARK: - Writing

  /// Sets what a task waits on and when to chase it, and files it in Waiting
  /// on if it is not there already. Nil clears either. One undo step, which
  /// includes the follow-up when the time set has already passed.
  public func setWaiting(
    taskId: String, waitingOn: String?, followUpAt: Date?, now: Date = .now
  ) throws {
    let tag = WaitingFollowUp.normalizedTag(waitingOn)
    // Whole minutes: the field takes nothing finer, and the follow-up's id is
    // derived from this instant.
    let followUpAt = followUpAt.map { Date(timeIntervalSince1970: ($0.timeIntervalSince1970 / 60).rounded(.down) * 60) }
    try journalledWrite("Waiting On") { db in
      guard try WorkspaceTask.fetchOne(db, key: taskId) != nil else { throw WorkspaceStoreError.missingTask }
      var record = try TaskMetadata.fetchOne(db, key: taskId) ?? TaskMetadata(
        taskId: taskId, priority: nil, startAt: nil, tagsJSON: "[]", recurrenceRule: nil,
        matrixUrgency: nil, matrixImportance: nil, kanbanColumn: nil, externalLinksJSON: "[]",
        updatedAt: now)
      if record.kanbanColumn != WaitingFollowUp.waitingColumnID {
        // Leaving Today drops the place in the day, as `setPlannedForToday` does.
        if record.kanbanColumn == NextUpSelector.todayColumnID { record.focusRank = nil }
        record.kanbanColumn = WaitingFollowUp.waitingColumnID
      }
      record.waitingOn = tag
      record.waitingFollowUpAt = followUpAt
      record.updatedAt = now
      try record.save(db)
      for state in try Self.waitingStates(db, taskId: taskId) {
        try Self.makeFollowUp(db, for: state, now: now)
      }
    }
  }

  // MARK: - The engine

  /// Makes every follow-up that has come due. Not an undo step, like the
  /// habit pass: nobody asked for it, and undoing it would only have the
  /// next pass make it again. Returns whether anything was made.
  @discardableResult
  public func reconcileWaitingFollowUps(now: Date = .now) throws -> Bool {
    let due = try database.read { db in
      try Self.waitingStates(db, taskId: nil).contains { WaitingFollowUp.dueFollowUp(for: $0, now: now) != nil }
    }
    guard due else { return false }
    return try database.write { db in
      var made = false
      for state in try Self.waitingStates(db, taskId: nil) where try Self.makeFollowUp(db, for: state, now: now) {
        made = true
      }
      return made
    }
  }

  /// The waiting tasks with a follow-up time, as the policy reads them.
  static func waitingStates(_ db: Database, taskId: String?) throws -> [WaitingTaskState] {
    var sql = """
      SELECT t.id, t.title, t.status, m.kanbanColumn, m.waitingOn, m.waitingFollowUpAt, m.waitingFollowUpTaskId
      FROM task_metadata m JOIN tasks t ON t.id = m.taskId
      WHERE m.waitingFollowUpAt IS NOT NULL AND m.kanbanColumn = ? AND t.status = ?
      """
    var arguments: StatementArguments = [WaitingFollowUp.waitingColumnID, TaskStatus.open.rawValue]
    if let taskId {
      sql += " AND t.id = ?"
      arguments += [taskId]
    }
    return try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
      WaitingTaskState(
        taskId: row["id"], title: row["title"], isOpen: (row["status"] as String?) == TaskStatus.open.rawValue,
        column: row["kanbanColumn"], waitingOn: row["waitingOn"], followUpAt: row["waitingFollowUpAt"],
        madeFollowUpTaskId: row["waitingFollowUpTaskId"])
    }
  }

  /// Makes `state`'s follow-up if it is due: a sibling of the waiting task,
  /// in Today, due at the follow-up time, linked back by `followUpOfTaskId`.
  /// A row with the same id already there — another device made it and sync
  /// brought it — is kept, and only recorded as made.
  @discardableResult
  static func makeFollowUp(_ db: Database, for state: WaitingTaskState, now: Date) throws -> Bool {
    guard let plan = WaitingFollowUp.dueFollowUp(for: state, now: now),
      let source = try WorkspaceTask.fetchOne(db, key: state.taskId)
    else { return false }
    if try WorkspaceTask.fetchOne(db, key: plan.taskId) == nil {
      let order = try nextOrder(
        db, table: WorkspaceTask.databaseTableName, whereSQL: "listId = ? AND parentTaskId IS ?",
        arguments: [source.listId, source.parentTaskId])
      let task = WorkspaceTask(
        id: plan.taskId, listId: source.listId, parentTaskId: source.parentTaskId, title: plan.title,
        notes: "", status: .open, sortOrder: order, dueAt: plan.dueAt, estimateSeconds: nil,
        itemKind: .task, createdAt: now, updatedAt: now)
      try task.insert(db)
      try db.execute(sql: """
        INSERT INTO task_metadata(taskId, tagsJSON, externalLinksJSON, kanbanColumn, followUpOfTaskId, updatedAt)
        VALUES (?, '[]', '[]', ?, ?, ?)
        ON CONFLICT(taskId) DO UPDATE SET
          kanbanColumn = excluded.kanbanColumn, followUpOfTaskId = excluded.followUpOfTaskId,
          updatedAt = excluded.updatedAt
        """, arguments: [plan.taskId, WaitingFollowUp.followUpColumnID, source.id, now])
    }
    try db.execute(
      sql: "UPDATE task_metadata SET waitingFollowUpTaskId = ?, updatedAt = ? WHERE taskId = ?",
      arguments: [plan.taskId, now, source.id])
    return true
  }
}
