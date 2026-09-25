import Foundation

/// One day's or one week's worth of finished work.
public struct WorkTotals: Sendable, Equatable {
  /// Tasks closed in the period.
  public let completed: Int
  /// Seconds recorded against focus blocks in the period.
  public let seconds: Int

  public init(completed: Int, seconds: Int) {
    self.completed = completed
    self.seconds = seconds
  }

  public static let zero = WorkTotals(completed: 0, seconds: 0)
}

/// Today set against the week it belongs to.
///
/// Two numbers on their own say nothing — four tasks is a good day or a poor
/// one depending on the week around it. Everything here exists to give today a
/// denominator.
public struct WorkProgress: Sendable, Equatable {
  public let today: WorkTotals
  public let week: WorkTotals
  /// Days of the week that have already happened, today included. The divisor
  /// for the pace, so a Tuesday is not judged against a seven-day target.
  public let elapsedDays: Int

  public init(today: WorkTotals, week: WorkTotals, elapsedDays: Int) {
    self.today = today
    self.week = week
    self.elapsedDays = max(1, elapsedDays)
  }

  /// The week's time spread evenly over the days that have happened.
  public var averageSecondsPerDay: Int { week.seconds / elapsedDays }

  /// Today's time as a fraction of that average. 1.0 is an ordinary day for
  /// this week; above it, today is ahead of the week's own pace.
  ///
  /// Deliberately relative to the week rather than to a target the user never
  /// set: a goal they have to configure before the number means anything is a
  /// goal they will not configure.
  public var paceAgainstWeek: Double {
    let average = averageSecondsPerDay
    guard average > 0 else { return today.seconds > 0 ? 1 : 0 }
    return Double(today.seconds) / Double(average)
  }

  /// Today's share of everything logged this week, 0...1.
  public var shareOfWeek: Double {
    guard week.seconds > 0 else { return 0 }
    return min(1, Double(today.seconds) / Double(week.seconds))
  }

  public static let empty = WorkProgress(today: .zero, week: .zero, elapsedDays: 1)
}

/// Builds `WorkProgress` from raw completion and work-block timestamps.
///
/// Takes flat arrays rather than the store's record types so it can stay in
/// `PriorityCore` and be tested without a database.
public enum WorkProgressSummary {
  public static func summarise(
    completions: [Date],
    blocks: [(seconds: Int, recordedAt: Date)],
    now: Date,
    calendar: Calendar = .current
  ) -> WorkProgress {
    let startOfToday = calendar.startOfDay(for: now)
    let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
    let weekStart = startOfWeek(containing: now, calendar: calendar)

    // Half-open on both ends, so a stroke of midnight belongs to exactly one
    // day and one week.
    func totals(from start: Date, to end: Date) -> WorkTotals {
      WorkTotals(
        completed: completions.filter { $0 >= start && $0 < end }.count,
        seconds: blocks.reduce(0) { sum, block in
          block.recordedAt >= start && block.recordedAt < end
            ? sum + max(0, block.seconds) : sum
        })
    }

    let elapsed = (calendar.dateComponents([.day], from: weekStart, to: startOfToday).day ?? 0) + 1
    return WorkProgress(
      today: totals(from: startOfToday, to: endOfToday),
      week: totals(from: weekStart, to: endOfToday),
      elapsedDays: elapsed)
  }

  /// The user's own week, not a fixed Monday: `calendar.firstWeekday` is what
  /// every other date in the app is already read against.
  public static func startOfWeek(containing date: Date, calendar: Calendar = .current) -> Date {
    calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
  }
}
