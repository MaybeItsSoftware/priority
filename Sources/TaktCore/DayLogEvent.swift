import Foundation

/// The kinds of thing the daily log records.
///
/// The log is append-only — nothing is ever rewritten or removed — so undoing a
/// completion appends a compensating `.reopened` rather than deleting the
/// `.completed` it cancels; `DayLogAggregator.netCompletions` pairs the two off
/// when it projects a day. That keeps appends safe from anywhere and makes a
/// torn write survivable: a corrupt final line costs one event, not the history.
public enum DayLogEventKind: String, Codable, Sendable {
  case completed
  case reopened
  /// Checkvist's "won't do". Recorded so the day is honest about it, but never
  /// counted as a completion — closing a task by abandoning it is not progress.
  case invalidated
  case focusSessionEnded
  /// The user consciously pushed a due date forward. Distinct from letting a
  /// task rot: `DayLogAggregator` keeps deferrals out of the unfinished list so
  /// the Daily view doesn't nag about a decision that was deliberately made.
  case deferred
  /// The set of tasks that were due or starting on this day, captured once at
  /// rollover. This is what makes "planned vs done" derivable without the user
  /// ever having to plan their day by hand.
  case planSnapshot
  /// A daily ticked off. Kept distinct from `.completed` because the two net
  /// differently: a task completion survives until something reopens it, on any
  /// later day, whereas a daily is a fresh question every day and its tick only
  /// ever applies to the day it was made on.
  case dailyCompleted
  /// A daily un-ticked. Only cancels a tick made on the same logical day.
  case dailyUncompleted
}

/// One thing that happened, as recorded by the daily-log plugin.
///
/// `title` is denormalised deliberately: the log is the durable record, and a
/// day's entry has to still read correctly after the task itself has been
/// closed, renamed, or deleted from Checkvist.
public struct DayLogEvent: Codable, Equatable, Sendable {
  public let kind: DayLogEventKind
  public let at: Date
  public let taskId: Int
  public let title: String
  /// `.focusSessionEnded` only.
  public let durationSeconds: Int?
  /// `.planSnapshot` only.
  public let plannedTaskIds: [Int]?
  /// `.dailyCompleted` / `.dailyUncompleted` only. Optional so every line
  /// already written without it still decodes — the log is durable history and
  /// a schema addition must never invalidate it.
  public let dailyId: String?

  public init(
    kind: DayLogEventKind,
    at: Date,
    taskId: Int,
    title: String,
    durationSeconds: Int? = nil,
    plannedTaskIds: [Int]? = nil,
    dailyId: String? = nil
  ) {
    self.kind = kind
    self.at = at
    self.taskId = taskId
    self.title = title
    self.durationSeconds = durationSeconds
    self.plannedTaskIds = plannedTaskIds
    self.dailyId = dailyId
  }

  public static func completed(taskId: Int, title: String, at: Date) -> DayLogEvent {
    DayLogEvent(kind: .completed, at: at, taskId: taskId, title: title)
  }

  public static func reopened(taskId: Int, title: String, at: Date) -> DayLogEvent {
    DayLogEvent(kind: .reopened, at: at, taskId: taskId, title: title)
  }

  public static func invalidated(taskId: Int, title: String, at: Date) -> DayLogEvent {
    DayLogEvent(kind: .invalidated, at: at, taskId: taskId, title: title)
  }

  public static func focusSessionEnded(taskId: Int, title: String, seconds: Int, at: Date) -> DayLogEvent {
    DayLogEvent(
      kind: .focusSessionEnded,
      at: at,
      taskId: taskId,
      title: title,
      durationSeconds: max(0, seconds)
    )
  }

  public static func deferred(taskId: Int, title: String, at: Date) -> DayLogEvent {
    DayLogEvent(kind: .deferred, at: at, taskId: taskId, title: title)
  }

  /// `taskId` is 0 throughout the daily pair: a daily is not a Checkvist task
  /// and has no id in that space. `title` is denormalised for the same reason
  /// as everywhere else — the log has to still read after a daily is archived.
  public static func dailyCompleted(dailyId: String, title: String, at: Date) -> DayLogEvent {
    DayLogEvent(kind: .dailyCompleted, at: at, taskId: 0, title: title, dailyId: dailyId)
  }

  public static func dailyUncompleted(dailyId: String, title: String, at: Date) -> DayLogEvent {
    DayLogEvent(kind: .dailyUncompleted, at: at, taskId: 0, title: title, dailyId: dailyId)
  }

  /// `taskId` is 0 because a snapshot is about the day, not about one task.
  public static func planSnapshot(taskIds: [Int], at: Date) -> DayLogEvent {
    DayLogEvent(
      kind: .planSnapshot,
      at: at,
      taskId: 0,
      title: "",
      plannedTaskIds: taskIds
    )
  }
}
