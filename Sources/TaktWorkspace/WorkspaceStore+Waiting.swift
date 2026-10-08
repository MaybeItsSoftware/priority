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
    // The Rust core's `waiting::set_waiting`, which keeps the follow-up time
    // to the minute and makes a follow-up already due in the same step.
    try coreWrite {
      try core.setWaiting(
        taskId: taskId, waitingOn: waitingOn, followUpAtMs: followUpAt?.coreMilliseconds, nowMs: now.coreMilliseconds)
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
    // The Rust core's `waiting::make_due_follow_ups`, outside the journal.
    return try coreWrite { try core.reconcileWaitingFollowUps(nowMs: now.coreMilliseconds) }
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

}
