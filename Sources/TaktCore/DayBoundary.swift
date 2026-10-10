import Foundation
import TaktRustCore

/// Maps an instant onto the *logical* day it belongs to.
///
/// A day here starts at `rolloverHour`, not at midnight: work finished at 01:30
/// belongs to the day that began the previous morning, which is how people
/// actually account for a late session. Every projection in `DayLogAggregator`
/// keys off this, so changing the hour reshapes the whole history consistently
/// rather than leaving a seam at the point the setting changed.
///
/// The arithmetic is the Rust core's (`core/src/day_log.rs`), shared with the
/// CLI; this holds the hour and the calendar whose zone and first weekday it
/// passes. The core counts in the Gregorian calendar.
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
  /// identifiers — back into `dayKey`, into `summary(on:)`, into note paths.
  public func logicalDay(for date: Date) -> Date {
    Date(dayLogMilliseconds: dayBoundaryLogicalDay(boundary: core, atMs: date.dayLogMilliseconds))
  }

  /// `yyyy-MM-dd` for the logical day.
  public func dayKey(for date: Date) -> String {
    dayBoundaryDayKey(boundary: core, atMs: date.dayLogMilliseconds)
  }

  /// The logical day `offset` days away from the one containing `date`,
  /// stepped by the wall clock as `Calendar.date(byAdding: .day)` does.
  public func day(offsetBy offset: Int, from date: Date) -> Date {
    Date(
      dayLogMilliseconds: dayBoundaryDayOffset(
        boundary: core, offset: Int64(offset), fromMs: date.dayLogMilliseconds))
  }

  /// The `count` logical days ending on (and including) the day containing
  /// `date`, oldest first.
  public func days(endingOn date: Date, count: Int) -> [Date] {
    dayBoundaryDaysEndingOn(boundary: core, atMs: date.dayLogMilliseconds, count: Int64(count))
      .map(Date.init(dayLogMilliseconds:))
  }

  /// Start of the calendar week containing the logical day for `date`, used to
  /// bucket the year-range chart. Respects the calendar's `firstWeekday`, so a
  /// Monday-start locale gets Monday-start bars. Rollover-anchored, like the
  /// days, so it re-keys to itself.
  public func weekStart(for date: Date) -> Date {
    Date(dayLogMilliseconds: dayBoundaryWeekStart(boundary: core, atMs: date.dayLogMilliseconds))
  }

  /// The `count` week starts ending on (and including) the week containing
  /// `date`, oldest first.
  public func weeks(endingOn date: Date, count: Int) -> [Date] {
    dayBoundaryWeeksEndingOn(boundary: core, atMs: date.dayLogMilliseconds, count: Int64(count))
      .map(Date.init(dayLogMilliseconds:))
  }
}
