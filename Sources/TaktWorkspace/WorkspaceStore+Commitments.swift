import Foundation
import TaktRustCore

/// A periodic commitment to a task: a subtask carrying a habit whose source is
/// the task, so it appears in Dailies and Today on its days and ends when the
/// task is done. The model and its rules are the Rust core's
/// (`core/src/commitments.rs`).
public struct WorkspaceCommitment: Identifiable, Sendable, Equatable {
  public let dailyId: String
  /// The subtask that carries it.
  public let taskId: String
  /// The task it advances.
  public let parentTaskId: String
  public let title: String
  /// Its schedule in the recurrence syntax: "daily", "weekdays", "every friday".
  public let rule: String
  public let weekdays: Set<Int>
  public let intervalDays: Int?
  /// The start of the day it stops appearing, if it has one.
  public let expiresAt: Date?

  public var id: String { taskId }

  init(_ core: Commitment) {
    dailyId = core.dailyId
    taskId = core.taskId
    parentTaskId = core.parentTaskId
    title = core.title
    rule = core.rule
    weekdays = Set(core.schedule.weekdays.map { Int($0) })
    intervalDays = core.schedule.intervalDays.map { Int($0) }
    expiresAt = core.expiresAtMs.map(Date.init(coreMilliseconds:))
  }

  /// "every friday" → "Every friday"; what the inspector shows.
  public var ruleLabel: String {
    rule.prefix(1).uppercased() + rule.dropFirst()
  }

  /// Whether `rule` is a schedule a commitment can keep: the recurrence
  /// syntax ("daily", "weekdays", "every friday", "every 2 weeks") or a list
  /// of days ("mon, wed, fri").
  public static func isSchedule(_ rule: String) -> Bool {
    commitmentSchedule(rule: rule) != nil
  }

  /// The schedule as the core writes it back, or nil for one it cannot read.
  public static func normalizedRule(_ rule: String) -> String? {
    commitmentSchedule(rule: rule).map { commitmentRuleText(schedule: $0) }
  }

  /// The last day it appears: the day before it stops. What a form shows as
  /// "until".
  public func lastDay(calendar: Calendar = .current) -> Date? {
    expiresAt.flatMap { calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: $0)) }
  }

  /// The moment a commitment whose last day is `day` stops: the start of the
  /// day after.
  public static func expiry(forLastDay day: Date, calendar: Calendar = .current) -> Date {
    calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) ?? day
  }

  /// "Work on <task>".
  public static func defaultTitle(forTaskTitle title: String) -> String {
    commitmentDefaultTitle(taskTitle: title)
  }
}

/// What the commitment form saves.
public struct WorkspaceCommitmentDraft: Sendable, Equatable {
  public var title: String
  /// In the syntax `WorkspaceCommitment.isSchedule` accepts.
  public var rule: String
  /// The day it stops appearing; nil runs until the task is done.
  public var expiresAt: Date?

  public init(title: String, rule: String = "daily", expiresAt: Date? = nil) {
    self.title = title
    self.rule = rule
    self.expiresAt = expiresAt
  }
}

extension WorkspaceStore {
  /// Commits to `taskId` periodically, or rewrites the commitment on
  /// `commitmentTaskId`, as one undo step. Returns the subtask's id.
  @discardableResult
  public func saveCommitment(
    taskId: String, draft: WorkspaceCommitmentDraft, commitmentTaskId: String? = nil, now: Date = .now,
    calendar: Calendar = .current
  ) throws -> String {
    let core = CommitmentDraft(
      title: draft.title, rule: draft.rule, expiresAtMs: draft.expiresAt?.coreMilliseconds)
    return try coreWrite {
      try self.core.saveCommitment(
        taskId: taskId, draft: core, commitmentTaskId: commitmentTaskId, nowMs: now.coreMilliseconds,
        zone: calendar.timeZone.identifier)
    }
  }

  /// Stops a commitment: its daily is archived with its history, and the
  /// subtask is closed.
  public func stopCommitment(taskId: String, now: Date = .now, calendar: Calendar = .current) throws {
    try coreWrite {
      try core.stopCommitment(
        commitmentTaskId: taskId, nowMs: now.coreMilliseconds, zone: calendar.timeZone.identifier)
    }
  }

  /// The live commitments on a task, in the order of its subtasks.
  public func commitments(forTaskId taskId: String) throws -> [WorkspaceCommitment] {
    try Self.mappingCoreErrors { try core.commitments(taskId: taskId) }.map(WorkspaceCommitment.init)
  }

  /// Every live commitment in the workspace.
  public func allCommitments() throws -> [WorkspaceCommitment] {
    try Self.mappingCoreErrors { try core.allCommitments() }.map(WorkspaceCommitment.init)
  }

  /// The live commitment a subtask carries, if it is one.
  public func commitment(taskId: String) throws -> WorkspaceCommitment? {
    try Self.mappingCoreErrors { try core.commitment(taskId: taskId) }.map(WorkspaceCommitment.init)
  }
}
