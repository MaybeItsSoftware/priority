import Foundation
import TaktCore
import XCTest

final class DayPlanSelectorTests: XCTestCase {
  private var calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    return calendar
  }()
  /// Midday, so "today" has room either side of it within the same day.
  private let now = Date(timeIntervalSince1970: 1_750_075_200)

  private func candidate(
    _ id: String,
    due: Date? = nil,
    dueDate: String? = nil,
    start: Date? = nil,
    column: String? = nil,
    order: Int = 0,
    rank: Int? = nil
  ) -> NextUpCandidate {
    NextUpCandidate(
      id: id, title: id, dueAt: due, startAt: start, kanbanColumn: column,
      focusRank: rank, sortOrder: order, dueDate: dueDate)
  }

  private func plan(_ candidates: [NextUpCandidate], running: String? = nil) -> [DayPlanEntry] {
    DayPlanSelector.plan(candidates: candidates, runningID: running, now: now, calendar: calendar)
  }

  func testTheTodayColumnIsTheDay() {
    let entries = plan([candidate("a", column: "today"), candidate("b", column: "backlog")])
    XCTAssertEqual(entries.map(\.id), ["a"])
    XCTAssertEqual(entries.first?.reason, .planned)
  }

  func testDeadlinesAndStartsJoinWithoutBeingPlanned() {
    let entries = plan([
      candidate("planned", column: "today"),
      candidate("due", due: now.addingTimeInterval(3_600)),
      candidate("late", due: now.addingTimeInterval(-86_400)),
      candidate("starting", start: now.addingTimeInterval(-3_600)),
      candidate("someday")
    ])
    XCTAssertEqual(entries.map(\.id), ["planned", "late", "due", "starting"])
    XCTAssertEqual(entries.map(\.reason), [.planned, .overdue, .dueToday, .startsToday])
  }

  func testTomorrowAndYesterdayAreNotToday() {
    let entries = plan([
      candidate("tomorrow", due: now.addingTimeInterval(86_400)),
      candidate("startedYesterday", start: now.addingTimeInterval(-86_400))
    ])
    // A deadline twelve hours past midnight belongs to tomorrow, and a start
    // date that has already been and gone is not a reason on its own — only a
    // start that lands on the day itself is.
    XCTAssertEqual(entries.map(\.id), [])
  }

  func testTheRunningBlockHeadsTheDayWhereverItCameFrom() {
    let entries = plan(
      [candidate("planned", column: "today"), candidate("elsewhere")], running: "elsewhere")
    XCTAssertEqual(entries.map(\.id), ["elsewhere", "planned"])
    XCTAssertEqual(entries.first?.reason, .running)
  }

  func testATaskIsClaimedOnceByItsStrongestReason() {
    let entries = plan([candidate("a", due: now.addingTimeInterval(-60), column: "today")])
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries.first?.reason, .planned)
  }

  func testAHandRankOrdersThePlannedColumn() {
    let entries = plan([
      candidate("third", column: "today", order: 3),
      candidate("first", column: "today", order: 9, rank: 1),
      candidate("second", column: "today", order: 1)
    ])
    XCTAssertEqual(entries.map(\.id), ["first", "second", "third"])
  }

  func testACalendarDueDateCountsAsTheWholeDay() {
    let today = TaskCalendarDate.string(now, calendar: calendar)
    let entries = plan([candidate("a", dueDate: today)])
    XCTAssertEqual(entries.map(\.reason), [.dueToday])
  }
}
