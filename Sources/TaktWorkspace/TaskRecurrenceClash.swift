import Foundation
import TaktRustCore

/// A repeating task's dates moved onto or past its own next turn — the day
/// it would come round again anyway. The Rust core decides when that is
/// (`tasks::recurrence_clash`); this is how the screens word it.
public struct TaskRecurrenceClash: Equatable, Sendable {
  public let taskId: String
  public let rule: String
  /// When the task would have come round again.
  public let nextTurn: Date
  /// Where it is being moved to: the due date when it has one, else the start.
  public let movedTo: Date

  public init(taskId: String, rule: String, nextTurn: Date, movedTo: Date) {
    self.taskId = taskId
    self.rule = rule
    self.nextTurn = nextTurn
    self.movedTo = movedTo
  }

  init(_ core: RecurrenceClash) {
    self.init(
      taskId: core.taskId, rule: core.rule, nextTurn: Date(coreMilliseconds: core.nextTurnMs),
      movedTo: Date(coreMilliseconds: core.movedToMs))
  }

  /// `Water the plants comes round again on Mon 20 Oct`.
  public func title(task: String, day: (Date) -> String) -> String {
    "\(task) comes round again on \(day(nextTurn))"
  }

  /// Whether the move lands on the turn itself rather than past it.
  public func landsOnTurn(calendar: Calendar = .current) -> Bool {
    calendar.isDate(movedTo, inSameDayAs: nextTurn)
  }

  /// `Moving it to Mon 20 Oct lands on that turn.`
  public func message(day: (Date) -> String, calendar: Calendar = .current) -> String {
    "Moving it to \(day(movedTo)) \(landsOnTurn(calendar: calendar) ? "lands on" : "goes past") that turn."
  }

  /// The day as every prompt writes it: `Mon 20 Oct`.
  public static func dayText(_ date: Date, calendar: Calendar = .current) -> String {
    var format = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated)
    format.calendar = calendar
    format.timeZone = calendar.timeZone
    return date.formatted(format)
  }
}

/// What the person can do about a clash. The same three on every client.
public enum RecurrenceClashChoice: CaseIterable, Sendable {
  /// Save the move as it is: one task stands for both days. The default.
  case stack
  /// Save the move, then add a one-off copy at the same dates.
  case keepBoth
  /// Save nothing; the edit stays as it was so it can be changed.
  case cancel

  public var title: String {
    switch self {
    case .stack: "Stack on that day"
    case .keepBoth: "Keep both"
    case .cancel: "Cancel"
    }
  }

  public var detail: String? {
    switch self {
    case .stack: "One task stands for both days"
    case .keepBoth: "Adds a one-off copy that does not repeat"
    case .cancel: nil
    }
  }

  /// Whether the move is saved.
  public var saves: Bool { self != .cancel }
  /// Whether a one-off copy is added after it.
  public var addsCopy: Bool { self == .keepBoth }
}
