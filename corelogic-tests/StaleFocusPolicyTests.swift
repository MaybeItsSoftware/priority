import XCTest

@testable import TaktCore

final class StaleFocusPolicyTests: XCTestCase {
  private let calendar = Calendar(identifier: .gregorian)
  private lazy var boundary = DayBoundary(rolloverHour: 4, calendar: calendar)

  private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    var components = DateComponents()
    components.year = 2026
    components.month = 9
    components.day = day
    components.hour = hour
    components.minute = minute
    components.timeZone = TimeZone(identifier: "UTC")
    var calendar = self.calendar
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: components)!
  }

  private var utcBoundary: DayBoundary {
    var calendar = self.calendar
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return DayBoundary(rolloverHour: 4, calendar: calendar)
  }

  func testARunningSessionIsLeftAlone() {
    XCTAssertEqual(
      StaleFocusPolicy.resolution(
        pausedAt: nil, accumulatedSeconds: 900, now: date(25, 15), boundary: utcBoundary),
      .keep)
  }

  func testABlockPausedEarlierTodayStaysPaused() {
    XCTAssertEqual(
      StaleFocusPolicy.resolution(
        pausedAt: date(25, 9), accumulatedSeconds: 900, now: date(25, 15), boundary: utcBoundary),
      .keep)
  }

  /// A paused session with nothing on it is left over, not paused work: it
  /// goes the same day, or every close of the window looked like focus mode.
  func testAPausedSessionWithNoTaskIsDiscardedTheSameDay() {
    XCTAssertEqual(
      StaleFocusPolicy.resolution(
        pausedAt: date(25, 9), accumulatedSeconds: 210, hasActiveTask: false, now: date(25, 11),
        boundary: utcBoundary),
      .discard)
  }

  /// The logical day runs from 04:00, so a block paused at half midnight is
  /// still the same day's work when you come back an hour later.
  func testABlockPausedAfterMidnightBelongsToTheDayThatStarted() {
    XCTAssertEqual(
      StaleFocusPolicy.resolution(
        pausedAt: date(25, 23), accumulatedSeconds: 900, now: date(26, 1), boundary: utcBoundary),
      .keep)
  }

  func testYesterdaysBlockWithRealTimeIsClosedOut() {
    XCTAssertEqual(
      StaleFocusPolicy.resolution(
        pausedAt: date(24, 15), accumulatedSeconds: 900, now: date(25, 15), boundary: utcBoundary),
      .close)
  }

  /// The case that prompted this: quitting immediately after starting left a
  /// half-second block sitting unfinished for a day.
  func testYesterdaysBlockWithNoTimeIsDiscarded() {
    XCTAssertEqual(
      StaleFocusPolicy.resolution(
        pausedAt: date(24, 15), accumulatedSeconds: 0, now: date(25, 15), boundary: utcBoundary),
      .discard)
  }

  func testAnythingUnderAMinuteIsNotASitting() {
    XCTAssertEqual(
      StaleFocusPolicy.resolution(
        pausedAt: date(24, 15), accumulatedSeconds: 59, now: date(25, 15), boundary: utcBoundary),
      .discard)
    XCTAssertEqual(
      StaleFocusPolicy.resolution(
        pausedAt: date(24, 15), accumulatedSeconds: 60, now: date(25, 15), boundary: utcBoundary),
      .close)
  }

  func testASessionWithNoActiveTaskHasNothingToCredit() {
    XCTAssertEqual(
      StaleFocusPolicy.resolution(
        pausedAt: date(24, 15), accumulatedSeconds: 900, hasActiveTask: false,
        now: date(25, 15), boundary: utcBoundary),
      .discard)
  }

  func testAWeekOldBlockIsStillResolvedRatherThanRestored() {
    XCTAssertEqual(
      StaleFocusPolicy.resolution(
        pausedAt: date(18, 11), accumulatedSeconds: 1_500, now: date(25, 15), boundary: utcBoundary),
      .close)
  }
}
