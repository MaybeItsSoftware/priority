import Foundation

/// Maps an instant onto the *logical* day it belongs to.
///
/// A day here starts at `rolloverHour`, not at midnight: work finished at 01:30
/// belongs to the day that began the previous morning, which is how people
/// actually account for a late session. Every projection in `DayLogAggregator`
/// keys off this, so changing the hour reshapes the whole history consistently
/// rather than leaving a seam at the point the setting changed.
public struct DayBoundary: Equatable, Sendable {
  /// 04:00. Late enough that a session finishing after midnight still lands on
  /// the day it belonged to, early enough that it never swallows a real morning.
  public static let defaultRolloverHour = 4

  public let rolloverHour: Int
  public let calendar: Calendar

  public init(rolloverHour: Int = DayBoundary.defaultRolloverHour, calendar: Calendar = .current) {
    self.rolloverHour = min(23, max(0, rolloverHour))
    self.calendar = calendar
  }

  /// The instant the logical day containing `date` began. Under a 4am rollover,
  /// 2026-08-15 01:30 belongs to the day that started at 2026-08-14 04:00.
  ///
  /// **Idempotent, and it has to be.** These dates are passed around as day
  /// identifiers — back into `dayKey`, into `summary(on:)`, into note paths — so
  /// anchoring to midnight instead would put the anchor *before* its own
  /// rollover, and re-keying it would shift it another day earlier every time.
  public func logicalDay(for date: Date) -> Date {
    let shifted = calendar.date(byAdding: .hour, value: -rolloverHour, to: date) ?? date
    let midnight = calendar.startOfDay(for: shifted)
    // `bySettingHour` rather than adding an offset so a DST transition can't
    // land the anchor on the wrong calendar day.
    return calendar.date(bySettingHour: rolloverHour, minute: 0, second: 0, of: midnight)
      ?? midnight
  }

  /// `yyyy-MM-dd` for the logical day. Assembled from components rather than a
  /// `DateFormatter` because aggregation keys every event in the log and a
  /// formatter allocation per event is a real cost at a year's scale.
  public func dayKey(for date: Date) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: logicalDay(for: date))
    return String(
      format: "%04d-%02d-%02d",
      components.year ?? 0,
      components.month ?? 0,
      components.day ?? 0
    )
  }

  /// The logical day `offset` days away from the one containing `date`.
  public func day(offsetBy offset: Int, from date: Date) -> Date {
    let anchor = logicalDay(for: date)
    return calendar.date(byAdding: .day, value: offset, to: anchor) ?? anchor
  }

  /// The `count` logical days ending on (and including) the day containing
  /// `date`, oldest first.
  public func days(endingOn date: Date, count: Int) -> [Date] {
    guard count > 0 else { return [] }
    return (0..<count).reversed().map { day(offsetBy: -$0, from: date) }
  }

  /// Start of the calendar week containing the logical day for `date`, used to
  /// bucket the year-range chart. Respects the calendar's `firstWeekday`, so a
  /// Monday-start locale gets Monday-start bars.
  public func weekStart(for date: Date) -> Date {
    let day = logicalDay(for: date)
    let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: day)
    guard let midnight = calendar.date(from: components) else { return day }
    // Rollover-anchored for the same reason as `logicalDay`: a midnight week
    // start would re-key to the previous day.
    return calendar.date(bySettingHour: rolloverHour, minute: 0, second: 0, of: midnight)
      ?? midnight
  }

  /// The `count` week starts ending on (and including) the week containing
  /// `date`, oldest first.
  public func weeks(endingOn date: Date, count: Int) -> [Date] {
    guard count > 0 else { return [] }
    let anchor = weekStart(for: date)
    return (0..<count).reversed().compactMap {
      calendar.date(byAdding: .weekOfYear, value: -$0, to: anchor)
    }
  }
}
