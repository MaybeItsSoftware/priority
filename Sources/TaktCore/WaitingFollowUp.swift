import Foundation
import TaktRustCore

/// A task in the Waiting on column, as the follow-up engine reads it.
public struct WaitingTaskState: Equatable, Sendable {
  public var taskId: String
  public var title: String
  public var isOpen: Bool
  /// The board column it is filed in. Only `waiting-on` is waiting.
  public var column: String?
  /// Who or what it waits on — "Sam", "Legal", "invoice".
  public var waitingOn: String?
  /// When to chase it, if ever.
  public var followUpAt: Date?
  /// The follow-up already made for this task, if any. Compared with the id
  /// the current follow-up time would make, so a follow-up is made once per
  /// time set, and setting a new time makes a new one.
  public var madeFollowUpTaskId: String?

  public init(
    taskId: String, title: String, isOpen: Bool, column: String?, waitingOn: String?,
    followUpAt: Date?, madeFollowUpTaskId: String?
  ) {
    self.taskId = taskId
    self.title = title
    self.isOpen = isOpen
    self.column = column
    self.waitingOn = waitingOn
    self.followUpAt = followUpAt
    self.madeFollowUpTaskId = madeFollowUpTaskId
  }
}

/// The follow-up task to make: "Follow up with Sam: Contract signed".
public struct WaitingFollowUpPlan: Equatable, Sendable {
  /// Deterministic — see `WaitingFollowUp.followUpTaskId`.
  public let taskId: String
  public let sourceTaskId: String
  public let title: String
  /// The follow-up time, which is the new task's due time.
  public let dueAt: Date

  public init(taskId: String, sourceTaskId: String, title: String, dueAt: Date) {
    self.taskId = taskId
    self.sourceTaskId = sourceTaskId
    self.title = title
    self.dueAt = dueAt
  }
}

/// Waiting on: a task filed in the `waiting-on` column can name who or what
/// it waits on and when to chase it. At that time, if it is still open and
/// still waiting, a follow-up task lands in Today.
///
/// The follow-up's id is derived from the source's id and the follow-up time,
/// so two devices that both notice the same follow-up make the same row, and
/// sync merges the two into one rather than leaving a pair.
///
/// The rule, the title and the id are the Rust core's (`core/src/waiting.rs`),
/// which makes the follow-ups on every client; the date words a card shows
/// stay here, beside the formatter, since every waiting card asks for them.
public enum WaitingFollowUp {
  /// The board column a waiting task is filed in.
  public static let waitingColumnID = "waiting-on"
  /// Where the follow-up lands.
  public static let followUpColumnID = "today"
  /// The longest tag kept: it is a chip, not a note.
  public static let maximumTagLength = 40

  /// The follow-up to make for `task` at `now`, or nil.
  ///
  /// Nil unless the task is open, still in `waiting-on`, has a follow-up time
  /// at or before `now`, and has not already had the follow-up for that time
  /// made. A task that left waiting before its time never gets one.
  public static func dueFollowUp(for task: WaitingTaskState, now: Date) -> WaitingFollowUpPlan? {
    guard let followUpAt = task.followUpAt,
      let plan = waitingDueFollowUp(
        task: WaitingState(
          taskId: task.taskId, title: task.title, isOpen: task.isOpen, column: task.column,
          waitingOn: task.waitingOn, followUpAtMs: followUpAt.flooredMilliseconds,
          madeFollowUpTaskId: task.madeFollowUpTaskId),
        nowMs: now.flooredMilliseconds)
    else { return nil }
    return WaitingFollowUpPlan(
      taskId: plan.taskId, sourceTaskId: plan.sourceTaskId, title: plan.title, dueAt: followUpAt)
  }

  /// "Follow up with Sam: Contract signed", or "Follow up: Contract signed"
  /// when nothing is named.
  public static func title(for title: String, waitingOn: String?) -> String {
    waitingFollowUpTitle(title: title, waitingOn: waitingOn)
  }

  /// A tag trimmed and clipped to `maximumTagLength` characters, or nil when
  /// there is nothing left.
  public static func normalizedTag(_ text: String?) -> String? {
    waitingNormalizedTag(text: text)
  }

  /// A UUID-shaped id from SHA-256 of `takt.follow-up:<source>:<epoch seconds>`,
  /// uppercased as `UUID().uuidString` writes them, with the version 5 and
  /// RFC 4122 variant bits set. Every client computes it through the core.
  public static func followUpTaskId(sourceTaskId: String, followUpAt: Date) -> String {
    waitingFollowUpTaskId(sourceTaskId: sourceTaskId, followUpAtMs: followUpAt.flooredMilliseconds)
  }

  /// `↻ Thu 14:00` — the follow-up time as a card shows it. Today and
  /// tomorrow are named; a date past the coming week shows its day and month.
  public static func label(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
    "↻ " + dateTimeText(date, now: now, calendar: calendar)
  }

  /// `Today 14:00`, `Tomorrow 09:00`, `Thu 14:00`, `8 Oct 14:00`.
  public static func dateTimeText(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_GB")
    formatter.dateFormat = "HH:mm"
    let time = formatter.string(from: date)
    let today = calendar.startOfDay(for: now)
    let day = calendar.startOfDay(for: date)
    let offset = calendar.dateComponents([.day], from: today, to: day).day ?? 0
    switch offset {
    case 0: return "Today \(time)"
    case 1: return "Tomorrow \(time)"
    case 2..<7:
      formatter.dateFormat = "EEE"
    default:
      let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
      formatter.dateFormat = sameYear ? "d MMM" : "d MMM yyyy"
    }
    return "\(formatter.string(from: date)) \(time)"
  }

  /// `2026-10-08 14:00` — what the follow-up field reads back, and parses.
  public static func editableText(_ date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    return String(
      format: "%04d-%02d-%02d %02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
      parts.hour ?? 0, parts.minute ?? 0)
  }
}

extension Date {
  /// Whole milliseconds since 1970, rounded down, so the whole second a
  /// follow-up's id is made from is the one this date reads.
  fileprivate var flooredMilliseconds: Int64 { Int64((timeIntervalSince1970 * 1000).rounded(.down)) }
}
