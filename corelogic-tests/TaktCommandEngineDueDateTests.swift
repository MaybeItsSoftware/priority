import Foundation
import XCTest

@testable import TaktCore

final class CommandEngineDueDateTests: XCTestCase {
  func testResolveDueDateSupportsRelativeDateTimes() {
    let calendar = makeUTCCalendar()
    let now = makeDate(year: 2026, month: 3, day: 30, hour: 10, minute: 15, calendar: calendar)

    XCTAssertEqual(
      CommandEngine.resolveDueDate("today", now: now, calendar: calendar),
      "2026-03-30"
    )
    XCTAssertEqual(
      CommandEngine.resolveDueDate("today 14:30", now: now, calendar: calendar),
      "2026-03-30 14:30:00 +0000"
    )
    XCTAssertEqual(
      CommandEngine.resolveDueDate("tomorrow 9am", now: now, calendar: calendar),
      "2026-03-31 09:00:00 +0000"
    )
    XCTAssertEqual(
      CommandEngine.resolveDueDate("monday 11am", now: now, calendar: calendar),
      "2026-04-06 11:00:00 +0000"
    )
  }

  func testResolveDueDateSupportsAbsoluteDateTime() {
    let calendar = makeUTCCalendar()
    let now = makeDate(year: 2026, month: 3, day: 30, hour: 10, minute: 15, calendar: calendar)

    XCTAssertEqual(
      CommandEngine.resolveDueDate("2026-4-2", now: now, calendar: calendar),
      "2026-04-02"
    )
    XCTAssertEqual(
      CommandEngine.resolveDueDate("2026-4-2 8:05pm", now: now, calendar: calendar),
      "2026-04-02 20:05:00 +0000"
    )
  }

  func testResolveDueDateSupportsTimeOnlyAndRelativeOffsets() {
    let calendar = makeUTCCalendar()
    let now = makeDate(year: 2026, month: 3, day: 30, hour: 10, minute: 15, calendar: calendar)

    XCTAssertEqual(
      CommandEngine.resolveDueDate("9am", now: now, calendar: calendar),
      "2026-03-30 09:00:00 +0000"
    )
    XCTAssertEqual(
      CommandEngine.resolveDueDate("in 90m", now: now, calendar: calendar),
      "2026-03-30 11:45:00 +0000"
    )
  }

  private func makeUTCCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
  }

  private func makeDate(
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    minute: Int,
    calendar: Calendar
  ) -> Date {
    let components = DateComponents(
      calendar: calendar,
      timeZone: calendar.timeZone,
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: minute
    )
    return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
  }
}
