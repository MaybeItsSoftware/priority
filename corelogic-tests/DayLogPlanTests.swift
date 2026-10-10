import Foundation
import TaktCore
import XCTest

/// The daily log's once-a-day plan over the Checkvist tasks.
final class DayLogPlanTests: XCTestCase {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    return calendar
  }

  /// Midday, so a day either side is unambiguous.
  private var now: Date {
    calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 12))!
  }

  private func day(_ offset: Int) -> Date {
    calendar.date(byAdding: .day, value: offset, to: now)!
  }

  private func plan(_ tasks: [FixtureTask], starts: [Int: Date] = [:]) -> [Int] {
    DayLogPlan.plannedTaskIds(
      openTasks: tasks, startDate: { starts[$0.id] }, now: now, calendar: calendar)
  }

  func testOverdueDueTodayAndAsapArePlannedAndLaterDuesAreNot() {
    let tasks = [
      FixtureTask(id: 1, due: "x", dueDate: day(-3)),
      FixtureTask(id: 2, due: "x", dueDate: day(0)),
      FixtureTask(id: 3, due: "asap"),
      FixtureTask(id: 4, due: "today"),
      FixtureTask(id: 5, due: "x", dueDate: day(1)),
      FixtureTask(id: 6, due: "x", dueDate: day(5)),
      FixtureTask(id: 7),
    ]
    XCTAssertEqual(plan(tasks), [1, 2, 3, 4])
  }

  func testAStartDateThatHasArrivedPlansATaskWithoutATodayDue() {
    let tasks = [
      FixtureTask(id: 1),
      FixtureTask(id: 2, due: "x", dueDate: day(4)),
      FixtureTask(id: 3),
      FixtureTask(id: 4),
    ]
    let starts = [1: day(0), 2: day(-2), 3: day(1)]
    XCTAssertEqual(plan(tasks, starts: starts), [1, 2])
  }

  func testTheOrderOfTheTasksGivenIsKept() {
    let tasks = [
      FixtureTask(id: 9, due: "asap"),
      FixtureTask(id: 2, due: "x", dueDate: day(-1)),
      FixtureTask(id: 5, due: "today"),
    ]
    XCTAssertEqual(plan(tasks), [9, 2, 5])
  }
}
