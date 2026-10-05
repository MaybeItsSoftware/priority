import Foundation

/// The board column a habit's appearance lands in.
///
/// The raw values are the ids of the default board's columns
/// (`WorkspaceKanbanColumn.blitzitDefaults`), because that is what a task's
/// `kanbanColumn` stores. A board whose columns were renamed keeps those ids.
public enum HabitPlacement: String, CaseIterable, Sendable, Codable {
  case today = "today"
  case thisWeek = "this-week"
  case waiting = "waiting-on"

  public var label: String {
    switch self {
    case .today: "Today"
    case .thisWeek: "This week"
    case .waiting: "Waiting"
    }
  }
}

/// When a habit stops appearing.
public enum HabitExpiry: Equatable, Sendable {
  /// When the task it was made from is completed — the default for a habit
  /// made from a task: "practise drums" lasts as long as "learn drums" does.
  case whenSourceCompleted
  /// From the start of this day onwards.
  case on(Date)
  case never

  /// The stored `expiryRule` value.
  public var rule: String {
    switch self {
    case .whenSourceCompleted: "source"
    case .on: "date"
    case .never: "never"
    }
  }

  public var date: Date? {
    if case .on(let date) = self { return date }
    return nil
  }

  /// Reads the stored pair back. An unknown rule, or a date rule with no date,
  /// is `never`: a habit that silently stopped would be worse than one that
  /// keeps coming round until it is archived by hand.
  public init(rule: String?, date: Date?) {
    switch rule {
    case "source": self = .whenSourceCompleted
    case "date": self = date.map { .on($0) } ?? .never
    default: self = .never
    }
  }
}

/// How often a habit appears, as the form offers it. Stored as the daily's
/// weekday mask and interval (see `HabitFrequency.storage`), so every client
/// that already reads a daily's schedule reads a habit's too.
public enum HabitFrequency: Equatable, Sendable {
  case daily
  /// On these weekdays, `Calendar` numbering (1 = Sunday).
  case weekdays(Set<Int>)
  /// Every N days from the day it was made.
  case everyNDays(Int)
  /// Once a week, on the weekday it was made — every seven days.
  case weekly

  public static let weeklyInterval = 7

  /// `(weekdays, intervalDays)` as a daily stores them.
  public var storage: (weekdays: Set<Int>, intervalDays: Int?) {
    switch self {
    case .daily: return (Set(1...7), nil)
    case .weekdays(let days): return (days.isEmpty ? Set(1...7) : days, nil)
    case .everyNDays(let days): return (Set(1...7), days <= 1 ? nil : min(366, days))
    case .weekly: return (Set(1...7), Self.weeklyInterval)
    }
  }

  public init(weekdays: Set<Int>, intervalDays: Int?) {
    if let intervalDays, intervalDays > 1 {
      self = intervalDays == Self.weeklyInterval ? .weekly : .everyNDays(intervalDays)
    } else if weekdays.isEmpty || weekdays == Set(1...7) {
      self = .daily
    } else {
      self = .weekdays(weekdays)
    }
  }

  public var label: String {
    switch self {
    case .daily: return "Every day"
    case .weekly: return "Every week"
    case .everyNDays(let days): return days == 2 ? "Every other day" : "Every \(days) days"
    case .weekdays(let days):
      if days == [2, 3, 4, 5, 6] { return "Weekdays" }
      if days == [1, 7] { return "Weekends" }
      let names = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
      return days.sorted().filter { (1...7).contains($0) }.map { names[$0] }.joined(separator: " ")
    }
  }
}

/// Everything that decides whether a habit shows up on a day, in one value
/// with no database behind it.
public struct HabitRule: Equatable, Sendable {
  public var weekdays: Set<Int>
  public var intervalDays: Int?
  /// A day the interval lands on; also the first day the habit can appear.
  public var anchor: Date
  /// Off: a missed appearance is carried until it is done. On: a missed day
  /// is a gap, and the next appearance is the next scheduled day.
  public var dropsAtDayEnd: Bool
  public var expiry: HabitExpiry
  public var placement: HabitPlacement

  public init(
    weekdays: Set<Int> = Set(1...7), intervalDays: Int? = nil, anchor: Date,
    dropsAtDayEnd: Bool = true, expiry: HabitExpiry = .never, placement: HabitPlacement = .today
  ) {
    self.weekdays = weekdays.isEmpty ? Set(1...7) : weekdays
    self.intervalDays = intervalDays
    self.anchor = anchor
    self.dropsAtDayEnd = dropsAtDayEnd
    self.expiry = expiry
    self.placement = placement
  }
}

/// One day's appearance of a habit.
public struct HabitAppearance: Equatable, Sendable {
  /// The board column it lands in.
  public let column: String
  /// The scheduled day it belongs to — today, or an earlier day it is still
  /// owed for.
  public let dueDay: Date
  public var isCarriedOver: Bool

  public init(column: String, dueDay: Date, isCarriedOver: Bool) {
    self.column = column
    self.dueDay = dueDay
    self.isCarriedOver = isCarriedOver
  }
}

/// Should a habit appear on a day, has it expired, and where does it land.
public enum HabitPolicy {
  /// How far back a carried appearance is looked for. A habit nobody has done
  /// for longer than this is not owed any more; it is simply due again.
  public static let carryLookbackDays = 366

  /// Whether `day` is one of the habit's scheduled days. Never before the
  /// anchor: a habit made today owes nothing for last week.
  public static func isScheduled(_ rule: HabitRule, on day: Date, calendar: Calendar = .current) -> Bool {
    let anchor = calendar.startOfDay(for: rule.anchor)
    let target = calendar.startOfDay(for: day)
    guard target >= anchor else { return false }
    if let interval = rule.intervalDays, interval > 1 {
      let elapsed = calendar.dateComponents([.day], from: anchor, to: target).day ?? 0
      return elapsed % interval == 0
    }
    return rule.weekdays.contains(calendar.component(.weekday, from: target))
  }

  /// Whether the habit has stopped for good by `day`.
  ///
  /// - Parameter sourceCompleted: whether the task it was made from is closed
  ///   (or gone). Only consulted by `.whenSourceCompleted`.
  public static func isExpired(
    _ rule: HabitRule, on day: Date, sourceCompleted: Bool, calendar: Calendar = .current
  ) -> Bool {
    switch rule.expiry {
    case .never: return false
    case .whenSourceCompleted: return sourceCompleted
    case .on(let date): return calendar.startOfDay(for: day) >= calendar.startOfDay(for: date)
    }
  }

  /// The most recent scheduled day on or before `day`, if any since the anchor.
  public static func lastScheduledDay(
    _ rule: HabitRule, onOrBefore day: Date, calendar: Calendar = .current
  ) -> Date? {
    var cursor = calendar.startOfDay(for: day)
    let anchor = calendar.startOfDay(for: rule.anchor)
    for _ in 0...carryLookbackDays {
      guard cursor >= anchor else { return nil }
      if isScheduled(rule, on: cursor, calendar: calendar) { return cursor }
      guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { return nil }
      cursor = previous
    }
    return nil
  }

  /// Where the habit stands on `day`: nil when it should not be showing.
  ///
  /// - Parameters:
  ///   - lastDoneDay: the latest day it was ticked off, if ever.
  ///   - sourceCompleted: whether the task it was made from is closed.
  public static func appearance(
    _ rule: HabitRule, on day: Date, lastDoneDay: Date?, sourceCompleted: Bool,
    calendar: Calendar = .current
  ) -> HabitAppearance? {
    guard !isExpired(rule, on: day, sourceCompleted: sourceCompleted, calendar: calendar) else { return nil }
    let today = calendar.startOfDay(for: day)
    let lastDone = lastDoneDay.map { calendar.startOfDay(for: $0) }
    if lastDone == today { return nil }
    if isScheduled(rule, on: today, calendar: calendar) {
      return HabitAppearance(column: rule.placement.rawValue, dueDay: today, isCarriedOver: false)
    }
    guard !rule.dropsAtDayEnd,
      let owed = lastScheduledDay(rule, onOrBefore: today, calendar: calendar),
      lastDone.map({ $0 < owed }) ?? true
    else { return nil }
    return HabitAppearance(column: rule.placement.rawValue, dueDay: owed, isCarriedOver: true)
  }

  /// The column a habit's task should be in now, given where it is.
  ///
  /// - Returns: the column to write, `.some(nil)` to take it out of the
  ///   habit's column, or nil to leave it alone. A card the user moved
  ///   somewhere else by hand is theirs; only the habit's own column, or no
  ///   column at all, is managed.
  public static func reconciledColumn(
    current: String?, appearance: HabitAppearance?, placement: HabitPlacement
  ) -> String?? {
    if let appearance {
      return current == nil ? .some(appearance.column) : nil
    }
    return current == placement.rawValue ? .some(nil) : nil
  }

  /// `30m`, `1h`, `1h30`, `90` (minutes) — the capture bar's estimate syntax,
  /// plus a bare number, as seconds. Nil for empty or unreadable text.
  public static func estimateSeconds(from text: String) -> Int? {
    let word = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "")
    guard !word.isEmpty else { return nil }
    if let minutes = Int(word), minutes > 0 { return min(minutes * 60, TaskCaptureToken.maximumEstimateSeconds) }
    return TaskCaptureToken.estimate(word)
  }

  /// `2026-12-31`, `3w`, `friday`, `tomorrow` — the capture bar's date words.
  public static func date(from text: String, now: Date = .now, calendar: Calendar = .current) -> Date? {
    let word = text.trimmingCharacters(in: .whitespaces).lowercased()
    guard !word.isEmpty else { return nil }
    return TaskCaptureToken.due(word, now: now, calendar: calendar)
  }
}
