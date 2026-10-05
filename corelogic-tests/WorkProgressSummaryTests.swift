import XCTest

@testable import TaktCore

final class WorkProgressSummaryTests: XCTestCase {
  private var calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2  // Monday
    return calendar
  }()

  /// Wednesday 2025-09-24, mid-afternoon.
  private let now = Date(timeIntervalSince1970: 1_758_726_000)

  private func day(_ offset: Int, hour: Int = 10) -> Date {
    let start = calendar.startOfDay(for: now)
    let shifted = calendar.date(byAdding: .day, value: offset, to: start)!
    return calendar.date(byAdding: .hour, value: hour, to: shifted)!
  }

  func testSeparatesTodayFromTheRestOfTheWeek() {
    let progress = WorkProgressSummary.summarise(
      completions: [day(0), day(0, hour: 14), day(-1), day(-2)],
      blocks: [
        (seconds: 1_800, recordedAt: day(0)),
        (seconds: 900, recordedAt: day(0, hour: 13)),
        (seconds: 3_600, recordedAt: day(-1)),
      ],
      now: now, calendar: calendar)

    XCTAssertEqual(progress.today, WorkTotals(completed: 2, seconds: 2_700))
    XCTAssertEqual(progress.week, WorkTotals(completed: 4, seconds: 6_300))
  }

  func testWeekStopsAtTheStartOfTheUsersWeek() {
    // Wednesday's week begins on Monday, so Sunday is last week's.
    let progress = WorkProgressSummary.summarise(
      completions: [day(-3)],
      blocks: [(seconds: 7_200, recordedAt: day(-3))],
      now: now, calendar: calendar)

    XCTAssertEqual(progress.week, .zero)
    XCTAssertEqual(progress.elapsedDays, 3)
  }

  func testTomorrowsWorkIsNotCountedToday() {
    let progress = WorkProgressSummary.summarise(
      completions: [day(1)],
      blocks: [(seconds: 600, recordedAt: day(1))],
      now: now, calendar: calendar)

    XCTAssertEqual(progress.today, .zero)
    XCTAssertEqual(progress.week, .zero)
  }

  func testPaceComparesTodayWithTheWeeksOwnAverage() {
    // Three elapsed days, 3h logged in total: an average day is one hour.
    let progress = WorkProgressSummary.summarise(
      completions: [],
      blocks: [
        (seconds: 3_600, recordedAt: day(-2)),
        (seconds: 3_600, recordedAt: day(-1)),
        (seconds: 3_600, recordedAt: day(0)),
      ],
      now: now, calendar: calendar)

    XCTAssertEqual(progress.elapsedDays, 3)
    XCTAssertEqual(progress.averageSecondsPerDay, 3_600)
    XCTAssertEqual(progress.paceAgainstWeek, 1, accuracy: 0.001)
    XCTAssertEqual(progress.shareOfWeek, 1.0 / 3.0, accuracy: 0.001)
  }

  func testAnEmptyWeekHasNoPaceRatherThanADivisionByZero() {
    let progress = WorkProgressSummary.summarise(
      completions: [], blocks: [], now: now, calendar: calendar)

    XCTAssertEqual(progress.averageSecondsPerDay, 0)
    XCTAssertEqual(progress.paceAgainstWeek, 0)
    XCTAssertEqual(progress.shareOfWeek, 0)
  }

  func testNegativeBlockSecondsCannotSubtractFromTheDay() {
    let progress = WorkProgressSummary.summarise(
      completions: [],
      blocks: [(seconds: 600, recordedAt: day(0)), (seconds: -600, recordedAt: day(0))],
      now: now, calendar: calendar)

    XCTAssertEqual(progress.today.seconds, 600)
  }
}
