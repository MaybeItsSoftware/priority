import XCTest

@testable import TaktCore

final class DayForecastTests: XCTestCase {
  private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

  func testRemainingIsWhatEachEstimatedTaskStillOwes() {
    let forecast = DayForecast(
      entries: [
        .init(estimateSeconds: 3600, loggedSeconds: 1200),
        .init(estimateSeconds: 1800, loggedSeconds: 0),
      ], now: now)
    XCTAssertEqual(forecast.estimatedSeconds, 5400)
    XCTAssertEqual(forecast.loggedSeconds, 1200)
    XCTAssertEqual(forecast.remainingSeconds, 4200)
    XCTAssertEqual(forecast.unestimatedCount, 0)
    XCTAssertEqual(forecast.finishAt, now.addingTimeInterval(4200))
  }

  /// Running over on one task does not pay back time on another.
  func testOverrunTaskContributesNothing() {
    let forecast = DayForecast(
      entries: [
        .init(estimateSeconds: 600, loggedSeconds: 3000),
        .init(estimateSeconds: 900, loggedSeconds: 300),
      ], now: now)
    XCTAssertEqual(forecast.remainingSeconds, 600)
    XCTAssertEqual(forecast.loggedSeconds, 3300)
  }

  func testUnestimatedTasksAreCountedButNotForecast() {
    let forecast = DayForecast(
      entries: [
        .init(estimateSeconds: nil, loggedSeconds: 500),
        .init(estimateSeconds: 0, loggedSeconds: 0),
        .init(estimateSeconds: 1200, loggedSeconds: 0),
      ], now: now)
    XCTAssertEqual(forecast.unestimatedCount, 2)
    XCTAssertEqual(forecast.estimatedSeconds, 1200)
    XCTAssertEqual(forecast.remainingSeconds, 1200)
    XCTAssertEqual(forecast.loggedSeconds, 500)
  }

  func testNoFinishTimeWhenNothingRemains() {
    let done = DayForecast(entries: [.init(estimateSeconds: 600, loggedSeconds: 600)], now: now)
    XCTAssertEqual(done.remainingSeconds, 0)
    XCTAssertNil(done.finishAt)

    let unplanned = DayForecast(entries: [.init(estimateSeconds: nil, loggedSeconds: 0)], now: now)
    XCTAssertNil(unplanned.finishAt)

    let empty = DayForecast(entries: [], now: now)
    XCTAssertNil(empty.finishAt)
    XCTAssertEqual(empty.unestimatedCount, 0)
  }
}
