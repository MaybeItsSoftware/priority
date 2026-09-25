import Foundation
import PriorityCore

/// A recurring task rule stored as a raw string in UserDefaults.
///
/// A thin shell over `PeriodicSchedule`, which owns the vocabulary and the
/// arithmetic. It stays as its own type because the Checkvist side of the app
/// passes rules around as raw strings and validates them by constructing this;
/// what it must not be is a second implementation of the same phrases, which
/// is how the two drifted before.
struct RecurrenceRule: Equatable {
  let raw: String

  private var schedule: PeriodicSchedule? { PeriodicSchedule(raw) }

  // MARK: - Parsing

  static func from(_ raw: String) -> RecurrenceRule? {
    guard let schedule = PeriodicSchedule(raw) else { return nil }
    return RecurrenceRule(raw: schedule.raw)
  }

  // MARK: - Display

  var displayLabel: String { schedule?.displayLabel ?? raw.capitalized }

  // MARK: - Next Due Date

  func nextDueDate(from current: Date, calendar: Calendar = .current) -> Date? {
    schedule?.nextOccurrence(after: current, calendar: calendar)
  }
}
