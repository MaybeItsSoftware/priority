import Foundation
import TaktCore
import TaktWorkspace

/// What the habit sheet is up for: a task (make a habit from it, or edit the
/// habit on it), or nothing (a standalone habit). The nonce makes asking
/// twice for the same task a fresh sheet.
struct HabitRequest: Identifiable, Equatable {
  let taskID: String?
  let id = UUID()
}

/// The habit form's rules, apart from SwiftUI: the same choices, defaults
/// and messages as the Mac's `WorkspaceHabitOverlay` and Android's
/// `HabitForm`, so a habit made on any of them reads the same on the others.
enum HabitForm {
  /// The four ways the form offers to say how often.
  enum FrequencyKind: CaseIterable, Hashable {
    case daily, weekdays, everyNDays, weekly

    var label: String {
      switch self {
      case .daily: "Every day"
      case .weekdays: "On days"
      case .everyNDays: "Every N days"
      case .weekly: "Weekly"
      }
    }
  }

  /// The three ways a habit can end; "with its task" only for one made from a task.
  enum ExpiryKind: CaseIterable, Hashable {
    case source, date, never

    var label: String {
      switch self {
      case .source: "With its task"
      case .date: "On a date"
      case .never: "Never"
      }
    }
  }

  /// A field the form can point an error at.
  enum Field: Equatable { case title, estimate, expiryDate }

  struct Invalid: Equatable, Error {
    let message: String
    let field: Field
  }

  /// Monday first, as the Mac's chips run. Calendar numbering (1 = Sunday).
  static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]
  private static let weekdayNames = ["", "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]

  static func weekdayName(_ weekday: Int) -> String { weekdayNames[weekday] }

  static func kind(_ frequency: HabitFrequency) -> FrequencyKind {
    switch frequency {
    case .daily: .daily
    case .weekdays: .weekdays
    case .everyNDays: .everyNDays
    case .weekly: .weekly
    }
  }

  /// Switching kind: weekdays start Monday to Friday, every N days starts at 3 (or keeps its N).
  static func with(_ frequency: HabitFrequency, kind: FrequencyKind) -> HabitFrequency {
    switch kind {
    case .daily: return .daily
    case .weekdays:
      if case .weekdays = frequency { return frequency }
      return .weekdays([2, 3, 4, 5, 6])
    case .everyNDays:
      if case .everyNDays = frequency { return frequency }
      return .everyNDays(3)
    case .weekly: return .weekly
    }
  }

  /// Toggles a weekday; the last one cannot be taken away, and all seven is every day.
  static func toggle(_ weekday: Int, in frequency: HabitFrequency) -> HabitFrequency {
    guard case .weekdays(let days) = frequency else { return frequency }
    var next = days
    if days.contains(weekday) {
      guard days.count > 1 else { return frequency }
      next.remove(weekday)
    } else {
      next.insert(weekday)
    }
    return next.count == 7 ? .daily : .weekdays(next)
  }

  /// Every N days, nudged: never under 2 (that is every day) nor over 366.
  static func step(_ frequency: HabitFrequency, by delta: Int) -> HabitFrequency {
    guard case .everyNDays(let days) = frequency else { return frequency }
    return .everyNDays(min(366, max(2, days + delta)))
  }

  static func expiryKind(_ expiry: HabitExpiry) -> ExpiryKind {
    switch expiry {
    case .whenSourceCompleted: .source
    case .on: .date
    case .never: .never
    }
  }

  static func expiryKinds(hasSource: Bool) -> [ExpiryKind] {
    hasSource ? ExpiryKind.allCases : [.date, .never]
  }

  /// The line under "With its task", naming the task, as the Mac's option does.
  static func sourceHint(_ sourceTitle: String?) -> String {
    "Ends when \(sourceTitle.map { "“\($0)”" } ?? "its task") is done."
  }

  /// `30m`, `1h`, `1h30`: what the estimate field shows for a stored estimate.
  static func estimateText(_ seconds: Int?) -> String {
    guard let seconds else { return "" }
    let minutes = seconds / 60
    if minutes >= 60 && minutes % 60 == 0 { return "\(minutes / 60)h" }
    if minutes > 60 { return "\(minutes / 60)h\(minutes % 60)" }
    return "\(minutes)m"
  }

  /// `2026-12-31` in the calendar's zone: what the "Ends on" field reads.
  static func dayText(_ date: Date, calendar: Calendar = .current) -> String {
    let day = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
  }

  /// A month from today: where "On a date" starts when nothing is typed.
  static func defaultEndDate(now: Date = .now, calendar: Calendar = .current) -> Date {
    let today = calendar.startOfDay(for: now)
    return calendar.date(byAdding: .month, value: 1, to: today) ?? today
  }

  /// Checks and reads the typed fields into the draft the store saves.
  static func validate(
    _ draft: HabitDraft, estimateText: String, expiryDateText: String,
    now: Date = .now, calendar: Calendar = .current
  ) -> Result<HabitDraft, Invalid> {
    var result = draft
    result.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !result.title.isEmpty else { return .failure(Invalid(message: "A habit needs a name.", field: .title)) }
    let estimate = estimateText.trimmingCharacters(in: .whitespaces)
    if estimate.isEmpty {
      result.estimateSeconds = nil
    } else if let seconds = HabitPolicy.estimateSeconds(from: estimate) {
      result.estimateSeconds = seconds
    } else {
      return .failure(Invalid(message: "Write the estimate as 30m, 1h or 1h30.", field: .estimate))
    }
    if case .on = draft.expiry {
      guard let date = HabitPolicy.date(from: expiryDateText, now: now, calendar: calendar) else {
        return .failure(Invalid(message: "Write the end date as 2026-12-31, 3w or a weekday.", field: .expiryDate))
      }
      result.expiry = .on(date)
    }
    return .success(result)
  }
}
