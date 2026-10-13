import XCTest

@testable import TaktCore

/// The add field's slots: the order → and ← walk, and what each slot's keys
/// do to the task not yet made.
final class TaskEntrySlotsTests: XCTestCase {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2
    return calendar
  }

  /// Tuesday 13 October 2026, mid-morning.
  private var today: Date { Date(timeIntervalSince1970: 1_791_885_600) }

  private func day(_ offset: Int) -> Date {
    calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: today))!
  }

  func testRightWalksTheSlotsAndStopsAtTheLast() {
    XCTAssertEqual(TaskEntryFocus.text.next, .date)
    XCTAssertEqual(TaskEntryFocus.date.next, .conditions)
    XCTAssertEqual(TaskEntryFocus.conditions.next, .estimate)
    XCTAssertEqual(TaskEntryFocus.estimate.next, .estimate)
  }

  func testLeftWalksBackAndTheDateSlotLeadsToTheText() {
    XCTAssertEqual(TaskEntryFocus.estimate.previous, .conditions)
    XCTAssertEqual(TaskEntryFocus.conditions.previous, .date)
    XCTAssertEqual(TaskEntryFocus.date.previous, .text)
    XCTAssertEqual(TaskEntryFocus.text.previous, .text)
  }

  func testArrowsAndTabsMoveBetweenSlots() {
    var draft = TaskEntryDraft(focus: .date)
    XCTAssertEqual(draft.handle(key: "right", today: today, calendar: calendar), .handled)
    XCTAssertEqual(draft.focus, .conditions)
    XCTAssertEqual(draft.handle(key: "tab", today: today, calendar: calendar), .handled)
    XCTAssertEqual(draft.focus, .estimate)
    XCTAssertEqual(draft.handle(key: "shift+tab", today: today, calendar: calendar), .handled)
    XCTAssertEqual(draft.focus, .conditions)
    _ = draft.handle(key: "left", today: today, calendar: calendar)
    _ = draft.handle(key: "left", today: today, calendar: calendar)
    XCTAssertEqual(draft.focus, .text)
  }

  func testTheTextsKeysAreNotTheSlots() {
    var draft = TaskEntryDraft()
    XCTAssertEqual(draft.handle(key: "up", today: today, calendar: calendar), .ignored)
    XCTAssertEqual(draft.handle(key: "enter", today: today, calendar: calendar), .ignored)
    XCTAssertEqual(draft, TaskEntryDraft())
  }

  func testReturnSubmitsAndEscapeCancelsFromEverySlot() {
    for focus in [TaskEntryFocus.date, .conditions, .estimate] {
      var draft = TaskEntryDraft(focus: focus)
      XCTAssertEqual(draft.handle(key: "enter", today: today, calendar: calendar), .submit)
      XCTAssertEqual(draft.handle(key: "escape", today: today, calendar: calendar), .cancel)
    }
  }

  func testUpStepsTheDateFromTodayAndShiftUpAWeek() {
    var draft = TaskEntryDraft(focus: .date)
    _ = draft.handle(key: "up", today: today, calendar: calendar)
    XCTAssertEqual(draft.dueDate, day(0))
    _ = draft.handle(key: "up", today: today, calendar: calendar)
    XCTAssertEqual(draft.dueDate, day(1))
    _ = draft.handle(key: "shift+up", today: today, calendar: calendar)
    XCTAssertEqual(draft.dueDate, day(8))
    XCTAssertEqual(draft.handle(key: "delete", today: today, calendar: calendar), .handled)
    XCTAssertNil(draft.dueDate)
    _ = draft.handle(key: "shift+up", today: today, calendar: calendar)
    XCTAssertEqual(draft.dueDate, day(7))
  }

  func testDownOpensTheCalendarAndTheConditionsFinder() {
    var draft = TaskEntryDraft(focus: .date)
    XCTAssertEqual(draft.handle(key: "down", today: today, calendar: calendar), .openCalendar)
    draft.focus = .conditions
    XCTAssertEqual(draft.handle(key: "down", today: today, calendar: calendar), .openConditions)
    XCTAssertEqual(draft.handle(key: "space", today: today, calendar: calendar), .openConditions)
  }

  func testDeleteInConditionsTakesTheLastOne() {
    var draft = TaskEntryDraft(focus: .conditions, requirementGroups: [["home"], ["desk", "cafe"]])
    _ = draft.handle(key: "delete", today: today, calendar: calendar)
    XCTAssertEqual(draft.requirementGroups, [["home"]])
    _ = draft.handle(key: "delete", today: today, calendar: calendar)
    _ = draft.handle(key: "delete", today: today, calendar: calendar)
    XCTAssertEqual(draft.requirementGroups, [])
  }

  func testEstimateStepsThroughThePresets() {
    XCTAssertEqual(TaskEntryEstimate.stepped(nil, by: 1), 5)
    XCTAssertNil(TaskEntryEstimate.stepped(nil, by: -1))
    XCTAssertEqual(TaskEntryEstimate.stepped(15, by: 1), 30)
    XCTAssertEqual(TaskEntryEstimate.stepped(60, by: 1), 90)
    XCTAssertEqual(TaskEntryEstimate.stepped(20, by: 1), 30)
    XCTAssertEqual(TaskEntryEstimate.stepped(20, by: -1), 15)
    XCTAssertNil(TaskEntryEstimate.stepped(5, by: -1))
    XCTAssertEqual(TaskEntryEstimate.stepped(480, by: 1), 480)
    XCTAssertEqual(TaskEntryEstimate.stepped(600, by: -1), 480)
  }

  func testEstimateSlotKeys() {
    var draft = TaskEntryDraft(focus: .estimate)
    _ = draft.handle(key: "up", today: today, calendar: calendar)
    _ = draft.handle(key: "up", today: today, calendar: calendar)
    XCTAssertEqual(draft.estimateMinutes, 10)
    _ = draft.handle(key: "down", today: today, calendar: calendar)
    XCTAssertEqual(draft.estimateMinutes, 5)
    _ = draft.handle(key: "delete", today: today, calendar: calendar)
    XCTAssertNil(draft.estimateMinutes)
  }

  func testTypingDigitsSetsMinutesAndAnotherKeyStartsAfresh() {
    var draft = TaskEntryDraft(focus: .estimate, estimateMinutes: 45)
    _ = draft.handle(key: "2", today: today, calendar: calendar)
    XCTAssertEqual(draft.estimateMinutes, 2)
    _ = draft.handle(key: "5", today: today, calendar: calendar)
    XCTAssertEqual(draft.estimateMinutes, 25)
    XCTAssertEqual(draft.estimateSeconds, 1500)
    _ = draft.handle(key: "up", today: today, calendar: calendar)
    XCTAssertEqual(draft.estimateMinutes, 30)
    _ = draft.handle(key: "7", today: today, calendar: calendar)
    XCTAssertEqual(draft.estimateMinutes, 7)
    XCTAssertEqual(TaskEntryEstimate.typing(9, onto: 999, continuing: true), 999)
    XCTAssertNil(TaskEntryEstimate.typing(0, onto: nil, continuing: false))
  }

  func testDigitsAreOnlyTheEstimates() {
    var draft = TaskEntryDraft(focus: .date)
    XCTAssertEqual(draft.handle(key: "3", today: today, calendar: calendar), .ignored)
    XCTAssertNil(draft.dueDate)
  }

  func testEstimateLabels() {
    XCTAssertEqual(TaskEntryEstimate.label(15), "15m")
    XCTAssertEqual(TaskEntryEstimate.label(60), "1h")
    XCTAssertEqual(TaskEntryEstimate.label(90), "1.5h")
    XCTAssertEqual(TaskEntryEstimate.label(130), "2h 10m")
  }

  func testDateLabelsNameTheNearDays() {
    XCTAssertEqual(TaskEntryDate.label(day(0), today: today, calendar: calendar), "Today")
    XCTAssertEqual(TaskEntryDate.label(day(1), today: today, calendar: calendar), "Tomorrow")
    XCTAssertEqual(TaskEntryDate.label(day(-1), today: today, calendar: calendar), "Yesterday")
  }

  func testTheCalendarCursorMovesByDayWeekAndMonth() {
    XCTAssertEqual(TaskEntryCalendar.moved(day(0), by: "right", calendar: calendar), day(1))
    XCTAssertEqual(TaskEntryCalendar.moved(day(0), by: "left", calendar: calendar), day(-1))
    XCTAssertEqual(TaskEntryCalendar.moved(day(0), by: "down", calendar: calendar), day(7))
    XCTAssertEqual(TaskEntryCalendar.moved(day(0), by: "up", calendar: calendar), day(-7))
    XCTAssertEqual(
      TaskEntryCalendar.moved(day(0), by: "pagedown", calendar: calendar),
      calendar.date(byAdding: .month, value: 1, to: day(0)))
    XCTAssertNil(TaskEntryCalendar.moved(day(0), by: "x", calendar: calendar))
  }

  func testTheMonthIsLaidOutFromTheFirstWeekday() {
    // October 2026 starts on a Thursday: three blanks before it on a
    // Monday-first calendar, and 31 days in five rows.
    let weeks = TaskEntryCalendar.weeks(containing: today, calendar: calendar)
    XCTAssertEqual(weeks.count, 5)
    XCTAssertTrue(weeks.allSatisfy { $0.count == 7 })
    XCTAssertEqual(weeks[0].prefix(3).compactMap { $0 }.count, 0)
    XCTAssertEqual(weeks[0][3].map { calendar.component(.day, from: $0) }, 1)
    XCTAssertEqual(weeks.flatMap { $0 }.compactMap { $0 }.count, 31)
  }
}
