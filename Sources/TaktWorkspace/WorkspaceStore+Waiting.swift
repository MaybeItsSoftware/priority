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
    var details: [String: TaskWaitingDetails] = [:]
    for row in try Self.mappingCoreErrors({ try core.allMetadata() })
    where row.waitingOn != nil || row.waitingFollowUpAtMs != nil || row.followUpOfTaskId != nil {
      details[row.taskId] = TaskWaitingDetails(
        waitingOn: row.waitingOn, followUpAt: row.waitingFollowUpAtMs.map(Date.init(coreMilliseconds:)),
        followUpOfTaskId: row.followUpOfTaskId)
    }
    return details
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
    // The Rust core's `waiting::make_due_follow_ups`, outside the journal; it
    // reads first and skips the write when nothing is due.
    try coreWrite { try core.reconcileWaitingFollowUps(nowMs: now.coreMilliseconds) }
  }
}
