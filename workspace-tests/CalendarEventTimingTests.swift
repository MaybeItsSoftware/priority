import Foundation
import TaktWorkspace
import XCTest

/// The dates an event made from a workspace task is given — by the inspector's
/// button and the Google Calendar settings page's alike.
final class CalendarEventTimingTests: XCTestCase {
  private var directory: URL!
  private var store: WorkspaceStore!
  private var snapshot: TaskEditorSnapshot!
  private let calendar = Calendar(identifier: .gregorian)

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("CalendarEventTimingTests-\(UUID().uuidString)")
    store = try WorkspaceStore(databaseURL: directory.appendingPathComponent("workspace.sqlite"))
    let workspace = try store.bootstrapIfNeeded()
    let inbox = try XCTUnwrap(store.inbox(in: workspace.id))
    let task = try store.createTask(listId: inbox.id, title: "Dentist")
    snapshot = try store.taskEditorSnapshot(for: task.id)
  }

  override func tearDownWithError() throws {
    store = nil
    try? FileManager.default.removeItem(at: directory)
  }

  func testATaskWithNoDatesGetsAnUndatedTimedEvent() {
    XCTAssertEqual(
      snapshot.calendarEventTiming(calendar: calendar),
      CalendarEventTiming(date: nil, isAllDay: false))
  }

  func testAnExactDueTimeIsATimedEventAndOutranksEveryOtherDate() {
    let due = Date(timeIntervalSince1970: 1_800_000_000)
    snapshot.dueAt = due
    snapshot.planning = TaskPlanning(startAt: due.addingTimeInterval(-3600), dueDate: "2027-01-15")
    XCTAssertEqual(
      snapshot.calendarEventTiming(calendar: calendar),
      CalendarEventTiming(date: due, isAllDay: false))
  }

  func testADueDayIsAnAllDayEventOnThatDayAndOutranksTheStart() throws {
    snapshot.planning = TaskPlanning(
      startAt: Date(timeIntervalSince1970: 1_700_000_000), dueDate: "2027-01-15")
    let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 1, day: 15)))
    XCTAssertEqual(
      snapshot.calendarEventTiming(calendar: calendar),
      CalendarEventTiming(date: day, isAllDay: true))
  }

  func testAStartTimeAloneIsATimedEventThen() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    snapshot.planning = TaskPlanning(startAt: start)
    XCTAssertEqual(
      snapshot.calendarEventTiming(calendar: calendar),
      CalendarEventTiming(date: start, isAllDay: false))
  }

  func testADueDayThatDoesNotParseFallsThroughToTheStart() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    snapshot.planning = TaskPlanning(startAt: start, dueDate: "not a day")
    XCTAssertEqual(
      snapshot.calendarEventTiming(calendar: calendar),
      CalendarEventTiming(date: start, isAllDay: false))
  }
}
