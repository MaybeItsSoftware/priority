import Foundation
import TaktRustCore

/// How often a task comes round.
///
/// The vocabulary is the one already stored in `task_metadata.recurrenceRule`
/// — plain phrases a person would type, not an RFC 5545 subset:
///
///     daily            every day
///     weekdays         Monday to Friday
///     weekly           the same weekday each week
///     every 3 days     every N days
///     every 2 weeks    every N weeks
///     every monday     a named weekday
public struct PeriodicSchedule: Equatable, Sendable {
  public enum Cadence: Equatable, Sendable {
    case days(Int)
    case weeks(Int)
    /// Monday to Friday, skipping the weekend.
    case weekdays
    /// A `Calendar` weekday number, 1 = Sunday through 7 = Saturday.
    case weekday(Int)
  }

  /// The phrase as it was stored, normalised to lowercase.
  public let raw: String
  public let cadence: Cadence

  /// Nil for a phrase this app did not write. The vocabulary is the Rust
  /// core's (`core/src/periodic.rs`), which Android and the CLI read too.
  public init?(_ raw: String) {
    guard let cadence = periodicCadence(raw: raw) else { return nil }
    self.raw = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    self.cadence = Cadence(cadence)
  }

  /// A weekday's name or abbreviation ("monday", "thu"), as a `Calendar`
  /// weekday number.
  public static func weekdayNumber(from name: String) -> Int? {
    guard case .weekday(let weekday) = periodicCadence(raw: "every \(name)").map(Cadence.init) else {
      return nil
    }
    return weekday
  }

  // MARK: - Display

  public var displayLabel: String {
    switch cadence {
    case .days(1): return "Daily"
    case .weeks(1): return "Weekly"
    case .weekdays: return "Weekdays"
    case .days(let count): return "Every \(count) days"
    case .weeks(let count): return "Every \(count) weeks"
    case .weekday(let weekday): return "Every \(Self.weekdayName(weekday))"
    }
  }

  public static func weekdayName(_ weekday: Int) -> String {
    let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    guard (1...7).contains(weekday) else { return "Day \(weekday)" }
    return names[weekday - 1]
  }

  // MARK: - The next time round

  /// The first occurrence strictly after `reference`, and also strictly after
  /// `notBefore` when one is given.
  ///
  /// `notBefore` is what makes a schedule survive being ignored. Finishing a
  /// daily chore five days late and simply adding a day would put the next one
  /// four days in the past, where it is instantly overdue again — so the
  /// cadence is stepped until it lands in the future, keeping the rhythm
  /// (every third day stays every third day) rather than restarting it.
  ///
  /// Stepped by the Rust core on the wall clock in the calendar's time zone, so
  /// a task due at 9:00 stays at 9:00 across a clock change. Nil only for a
  /// cadence that cannot land, which no parseable rule produces.
  public func nextOccurrence(
    after reference: Date,
    notBefore: Date? = nil,
    calendar: Calendar = .current
  ) -> Date? {
    periodicNextOccurrence(
      cadence: cadence.core, afterMs: reference.rankingMilliseconds, notBeforeMs: notBefore?.rankingMilliseconds,
      zone: calendar.timeZone.identifier
    ).map(Date.init(rankingMilliseconds:))
  }
}

extension PeriodicSchedule.Cadence {
  init(_ core: PeriodicCadence) {
    switch core {
    case .days(let count): self = .days(Int(count))
    case .weeks(let count): self = .weeks(Int(count))
    case .weekdays: self = .weekdays
    case .weekday(let weekday): self = .weekday(Int(weekday))
    }
  }

  var core: PeriodicCadence {
    switch self {
    case .days(let count): .days(count: UInt32(clamping: count))
    case .weeks(let count): .weeks(count: UInt32(clamping: count))
    case .weekdays: .weekdays
    case .weekday(let weekday): .weekday(weekday: UInt32(clamping: weekday))
    }
  }
}
