import Foundation

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

  public init?(_ raw: String) {
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let cadence = Self.parse(normalized) else { return nil }
    self.raw = normalized
    self.cadence = cadence
  }

  // MARK: - Parsing

  private static func parse(_ text: String) -> Cadence? {
    switch text {
    case "": return nil
    case "daily", "every day": return .days(1)
    case "weekly", "every week": return .weeks(1)
    case "weekdays", "every weekday": return .weekdays
    default: break
    }
    if let interval = everyNInterval(in: text) { return interval }
    if let weekday = weekdayNumber(
      from: text.hasPrefix("every ") ? String(text.dropFirst("every ".count)) : text)
    {
      return .weekday(weekday)
    }
    return nil
  }

  private static func everyNInterval(in text: String) -> Cadence? {
    let pattern = #"^every\s+(\d+)\s+(day|days|week|weeks|wk|wks)$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let countRange = Range(match.range(at: 1), in: text),
      let unitRange = Range(match.range(at: 2), in: text),
      let count = Int(text[countRange]), count > 0
    else { return nil }
    let unit = String(text[unitRange])
    return unit.hasPrefix("week") || unit.hasPrefix("wk") ? .weeks(count) : .days(count)
  }

  public static func weekdayNumber(from name: String) -> Int? {
    switch name {
    case "sunday", "sun": return 1
    case "monday", "mon": return 2
    case "tuesday", "tue", "tues": return 3
    case "wednesday", "wed": return 4
    case "thursday", "thu", "thur", "thurs": return 5
    case "friday", "fri": return 6
    case "saturday", "sat": return 7
    default: return nil
    }
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
  /// Nil only for a cadence that cannot land, which no parseable rule produces.
  public func nextOccurrence(
    after reference: Date,
    notBefore: Date? = nil,
    calendar: Calendar = .current
  ) -> Date? {
    let threshold = max(reference, notBefore ?? reference)
    var candidate = reference
    // One year of daily steps is the widest a valid cadence can need to cross
    // any gap worth honouring; past that the rule is not one worth keeping.
    for _ in 0..<400 {
      guard let stepped = step(from: candidate, calendar: calendar) else { return nil }
      candidate = stepped
      if candidate > threshold { return candidate }
    }
    return nil
  }

  private func step(from date: Date, calendar: Calendar) -> Date? {
    switch cadence {
    case .days(let count):
      return calendar.date(byAdding: .day, value: count, to: date)
    case .weeks(let count):
      return calendar.date(byAdding: .weekOfYear, value: count, to: date)
    case .weekdays:
      guard var next = calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
      while calendar.component(.weekday, from: next) == 1
        || calendar.component(.weekday, from: next) == 7
      {
        guard let onward = calendar.date(byAdding: .day, value: 1, to: next) else { return nil }
        next = onward
      }
      return next
    case .weekday(let weekday):
      guard var next = calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
      for _ in 0..<7 {
        if calendar.component(.weekday, from: next) == weekday { return next }
        guard let onward = calendar.date(byAdding: .day, value: 1, to: next) else { return nil }
        next = onward
      }
      return next
    }
  }
}
