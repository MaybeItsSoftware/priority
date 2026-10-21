import Foundation

/// A save that starts a task on a later day while it has a deadline. The
/// Rust core takes it out of Today (`refile_by_start`); what happens to the
/// deadline is the person's to say, so the Mac asks first. Left alone the
/// core would move a deadline set with the task along with the start, keep
/// one set by hand, and refuse the save when that one is not after the start.
public struct TaskStartLater: Equatable, Sendable {
  /// When the task now starts.
  public let start: Date
  /// The deadline as it stands, and whether it is a time or a whole day.
  public let due: Date
  public let dueIsDay: Bool
  /// Where moving it with the start puts it: by as much as the start moved,
  /// or onto the start's day when that would land at or before the start.
  public let movedDueAt: Date?
  public let movedDueDate: String?
  /// Whether keeping the deadline is a choice: only when it is still after
  /// the new start, since the core refuses a task due before it begins.
  public let canKeep: Bool

  /// What the edit in `draft` asks, or nil when there is nothing to ask:
  /// the task has to have a deadline the edit did not change itself, and the
  /// start has to move either to another day after today or, on any day, to
  /// where the deadline no longer comes after it — which the core would refuse.
  public static func check(
    _ draft: TaskEditorDraft, now: Date = .now, calendar: Calendar = .current
  ) -> TaskStartLater? {
    let values = draft.values, saved = draft.baseline.values
    guard let start = values.startAt, start != saved.startAt,
      values.dueAt == saved.dueAt, values.dueDate == saved.dueDate,
      let asked = asking(values: values, saved: saved, start: start, now: now, calendar: calendar)
    else { return nil }
    let laterDay = calendar.startOfDay(for: start) > calendar.startOfDay(for: now)
      && (saved.startAt.map({ !calendar.isDate($0, inSameDayAs: start) }) ?? true)
    return laterDay || !asked.canKeep ? asked : nil
  }

  private static func asking(
    values: TaskEditorValues, saved: TaskEditorValues, start: Date, now: Date, calendar: Calendar
  ) -> TaskStartLater? {

    let from = saved.startAt ?? now
    let days = calendar.dateComponents(
      [.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: start)
    ).day ?? 0
    let startDay = dayString(start, calendar: calendar)

    if let day = values.dueDate, let dueDay = date(fromDay: day, calendar: calendar) {
      let moved = calendar.date(byAdding: .day, value: days, to: dueDay) ?? dueDay
      // A due day ends at its midnight; the start's own day is the earliest it can be.
      let movedDay = endOfDay(moved, calendar: calendar) > start ? dayString(moved, calendar: calendar) : startDay
      return TaskStartLater(
        start: start, due: dueDay, dueIsDay: true, movedDueAt: nil, movedDueDate: movedDay,
        canKeep: endOfDay(dueDay, calendar: calendar) > start)
    }
    guard let dueAt = values.dueAt else { return nil }
    // The core moves a due time by exactly as long as the start moved. With
    // no start before it doesn't move it at all; "move" then shifts it by
    // the whole days from today to the new start.
    let moved = saved.startAt.map { dueAt.addingTimeInterval(start.timeIntervalSince($0)) }
      ?? calendar.date(byAdding: .day, value: days, to: dueAt) ?? dueAt
    let fits = moved > start
    return TaskStartLater(
      start: start, due: dueAt, dueIsDay: false,
      movedDueAt: fits ? moved : nil, movedDueDate: fits ? nil : startDay,
      canKeep: dueAt > start)
  }

  /// The choices to offer, the one to pick by default first.
  public var choices: [StartLaterChoice] {
    canKeep ? [.keep, .move, .clear, .cancel] : [.move, .clear, .cancel]
  }

  /// Makes `values` say what `choice` means. Returns whether the save has to
  /// keep the deadline where it is (`saveTaskEditor(_:keepingDue:)`).
  @discardableResult
  public func apply(_ choice: StartLaterChoice, to values: inout TaskEditorValues) -> Bool {
    switch choice {
    case .keep, .cancel:
      return choice == .keep
    case .move:
      values.dueAt = movedDueAt
      values.dueDate = movedDueDate
    case .clear:
      values.dueAt = nil
      values.dueDate = nil
    }
    return false
  }

  /// The deadline a choice leaves, for its row: the day, and the time when it has one.
  public func dueText(for choice: StartLaterChoice, calendar: Calendar = .current) -> String? {
    switch choice {
    case .keep: Self.text(due, withTime: !dueIsDay, calendar: calendar)
    case .move:
      movedDueAt.map { Self.text($0, withTime: true, calendar: calendar) }
        ?? movedDueDate.flatMap { Self.date(fromDay: $0, calendar: calendar) }
        .map { Self.text($0, withTime: false, calendar: calendar) }
    case .clear, .cancel: nil
    }
  }

  public static func text(_ date: Date, withTime: Bool, calendar: Calendar = .current) -> String {
    var format = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated)
    if withTime { format = format.hour().minute() }
    format.calendar = calendar
    format.timeZone = calendar.timeZone
    return date.formatted(format)
  }

  private static func dayString(_ date: Date, calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  private static func date(fromDay day: String, calendar: Calendar) -> Date? {
    let parts = day.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
  }

  private static func endOfDay(_ date: Date, calendar: Calendar) -> Date {
    calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date
  }
}

/// What the person can do about the deadline when the start moves later.
public enum StartLaterChoice: Sendable {
  /// The deadline stays where it is. The default when it still can.
  case keep
  /// The deadline moves with the start.
  case move
  /// The task has no deadline any more.
  case clear
  /// Save nothing; the edit stays as it was.
  case cancel

  public var title: String {
    switch self {
    case .keep: "Keep the due date"
    case .move: "Move it with the start"
    case .clear: "No due date"
    case .cancel: "Cancel"
    }
  }

  /// Whether the edit is saved.
  public var saves: Bool { self != .cancel }
}
