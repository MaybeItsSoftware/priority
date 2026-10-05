import Foundation
import TaktCore
import XCTest

final class TaskProgressSeriesTests: XCTestCase {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    return calendar
  }

  private func date(_ day: Int, _ hour: Int = 12, month: Int = 3) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
  }

  func testEveryDayOfThePeriodIsPresentEmptyOnesIncluded() {
    let series = TaskProgressSeries.build(
      period: .week, completions: [], creations: [], now: date(20), calendar: calendar)
    XCTAssertEqual(series.days.count, 7)
    XCTAssertEqual(series.days.first?.dayStart, calendar.startOfDay(for: date(14)))
    XCTAssertEqual(series.days.last?.dayStart, calendar.startOfDay(for: date(20)))
    XCTAssertTrue(series.days.allSatisfy { $0.completed == 0 && $0.added == 0 })
  }

  func testCountsCompletionsAndCreationsPerDayWithARunningTotal() {
    let series = TaskProgressSeries.build(
      period: .week,
      completions: [date(15, 9), date(15, 23), date(18, 0)],
      creations: [date(15), date(19), date(19), date(20)],
      now: date(20, 8), calendar: calendar)
    XCTAssertEqual(series.days.map(\.completed), [0, 2, 0, 0, 1, 0, 0])
    XCTAssertEqual(series.days.map(\.added), [0, 1, 0, 0, 0, 2, 1])
    XCTAssertEqual(series.days.map(\.cumulativeCompleted), [0, 2, 2, 2, 3, 3, 3])
    XCTAssertEqual(series.totalCompleted, 3)
    XCTAssertEqual(series.totalAdded, 4)
    XCTAssertEqual(series.net, -1)
    XCTAssertEqual(series.bestDay?.dayStart, calendar.startOfDay(for: date(15)))
  }

  func testTimesOutsideThePeriodAreIgnoredNotClamped() {
    let series = TaskProgressSeries.build(
      period: .week, completions: [date(13, 23), date(21, 0)], creations: [date(1)],
      now: date(20), calendar: calendar)
    XCTAssertEqual(series.totalCompleted, 0)
    XCTAssertEqual(series.totalAdded, 0)
    XCTAssertNil(series.bestDay)
  }

  func testTheIntervalRunsFromTheFirstDaysStartToTheEndOfToday() {
    let interval = TaskProgressSeries.interval(for: .month, now: date(20, 15), calendar: calendar)
    XCTAssertEqual(interval.start, calendar.startOfDay(for: calendar.date(byAdding: .day, value: -29, to: date(20))!))
    XCTAssertEqual(interval.end, calendar.startOfDay(for: date(21)))
  }

  func testADaylightSavingChangeStillGivesOneBucketPerDay() {
    // The clocks go forward in London on 29 March 2026.
    let series = TaskProgressSeries.build(
      period: .week, completions: [date(29, 3)], creations: [], now: date(1, 12, month: 4), calendar: calendar)
    XCTAssertEqual(series.days.count, 7)
    XCTAssertEqual(Set(series.days.map(\.dayStart)).count, 7)
    XCTAssertEqual(series.totalCompleted, 1)
  }
}
