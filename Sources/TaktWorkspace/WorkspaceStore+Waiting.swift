import Foundation
import TaktCore

/// What a card shows about a task that is waiting, or that chases one.
public struct TaskWaitingDetails: Sendable, Equatable {
  public var waitingOn: String?
  public var followUpAt: Date?
  /// On a follow-up task: the waiting task it chases.
  public var followUpOfTaskId: String?
  /// Chase again every this many days after a follow-up is done; nil is once.
  public var followUpEveryDays: Int?
  /// What a card adds after the follow-up time: `#3 · every 3d`, or nil for
  /// a first follow-up that happens once. The core's `waiting::chase_label`.
  public var chase: String?

  public init(
    waitingOn: String? = nil, followUpAt: Date? = nil, followUpOfTaskId: String? = nil,
    followUpEveryDays: Int? = nil, chase: String? = nil
  ) {
    self.waitingOn = waitingOn
    self.followUpAt = followUpAt
    self.followUpOfTaskId = followUpOfTaskId
    self.followUpEveryDays = followUpEveryDays
    self.chase = chase
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
    for row in try Self.mappingCoreErrors({ try core.waitingMetadata() })
    where row.waitingOn != nil || row.waitingFollowUpAtMs != nil || row.followUpOfTaskId != nil {
      details[row.taskId] = TaskWaitingDetails(
        waitingOn: row.waitingOn, followUpAt: row.waitingFollowUpAtMs.map(Date.init(coreMilliseconds:)),
        followUpOfTaskId: row.followUpOfTaskId, followUpEveryDays: row.waitingFollowUpEveryDays.map(Int.init),
        chase: row.waitingFollowUpAtMs.flatMap {
          WaitingFollowUp.chase(
            sourceTaskId: row.taskId, followUpAt: Date(coreMilliseconds: $0),
            madeFollowUpTaskId: row.waitingFollowUpTaskId, count: Int(row.waitingFollowUpCount),
            everyDays: row.waitingFollowUpEveryDays.map(Int.init))
        })
    }
    return details
  }

  // MARK: - Writing

  /// Sets what a task waits on, when to chase it and every how many days to
  /// chase again (nil for once), and files it in Waiting on if it is not
  /// there already. Nil clears any of them. One undo step, which includes the
  /// follow-up when the time set has already passed. The repeat has no
  /// default, so a caller changing only the tag has to pass the one it has.
  public func setWaiting(
    taskId: String, waitingOn: String?, followUpAt: Date?, everyDays: Int?, now: Date = .now
  ) throws {
    // The Rust core's `waiting::set_waiting`, which keeps the follow-up time
    // to the minute, refuses a repeat outside 1 to 365 days, and makes a
    // follow-up already due in the same step.
    try coreWrite {
      try core.setWaiting(
        taskId: taskId, waitingOn: waitingOn, followUpAtMs: followUpAt?.coreMilliseconds,
        followUpEveryDays: everyDays.map { UInt32(clamping: $0) }, nowMs: now.coreMilliseconds)
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
