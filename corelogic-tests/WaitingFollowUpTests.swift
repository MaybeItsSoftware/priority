import XCTest

@testable import TaktCore

/// Waiting on: when a follow-up is due, what it is called, the id two devices
/// agree on, and the follow-up field's date and time words.
final class WaitingFollowUpTests: XCTestCase {
  private var calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  /// Tuesday 6 October 2026, 10:00 UTC.
  private var now: Date { date(2026, 10, 6, 10) }

  private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
  }

  private func waiting(
    followUpAt: Date?, column: String? = "waiting-on", isOpen: Bool = true, tag: String? = "Sam",
    made: String? = nil
  ) -> WaitingTaskState {
    WaitingTaskState(
      taskId: "SOURCE", title: "Contract signed", isOpen: isOpen, column: column, waitingOn: tag,
      followUpAt: followUpAt, madeFollowUpTaskId: made)
  }

  // MARK: - The engine

  func testAFollowUpIsDueAtItsTimeWhileTheTaskIsStillWaiting() {
    let at = date(2026, 10, 6, 9)
    let plan = WaitingFollowUp.dueFollowUp(for: waiting(followUpAt: at), now: now)
    XCTAssertEqual(plan?.title, "Follow up with Sam: Contract signed")
    XCTAssertEqual(plan?.dueAt, at)
    XCTAssertEqual(plan?.sourceTaskId, "SOURCE")
    XCTAssertEqual(plan?.taskId, WaitingFollowUp.followUpTaskId(sourceTaskId: "SOURCE", followUpAt: at))
    // Exactly at the time counts.
    XCTAssertNotNil(WaitingFollowUp.dueFollowUp(for: waiting(followUpAt: now), now: now))
  }

  func testNothingIsDueBeforeTheTimeOrWithoutOne() {
    XCTAssertNil(WaitingFollowUp.dueFollowUp(for: waiting(followUpAt: date(2026, 10, 6, 11)), now: now))
    XCTAssertNil(WaitingFollowUp.dueFollowUp(for: waiting(followUpAt: nil), now: now))
  }

  func testATaskThatLeftWaitingOrClosedGetsNoFollowUp() {
    let at = date(2026, 10, 6, 9)
    XCTAssertNil(WaitingFollowUp.dueFollowUp(for: waiting(followUpAt: at, column: "today"), now: now))
    XCTAssertNil(WaitingFollowUp.dueFollowUp(for: waiting(followUpAt: at, column: nil), now: now))
    XCTAssertNil(WaitingFollowUp.dueFollowUp(for: waiting(followUpAt: at, isOpen: false), now: now))
  }

  func testAFollowUpIsMadeOncePerTimeSet() {
    let at = date(2026, 10, 6, 9)
    let made = WaitingFollowUp.followUpTaskId(sourceTaskId: "SOURCE", followUpAt: at)
    XCTAssertNil(WaitingFollowUp.dueFollowUp(for: waiting(followUpAt: at, made: made), now: now))
    // Setting a new time after the first one fired makes a new follow-up.
    let later = date(2026, 10, 6, 9, 30)
    let plan = WaitingFollowUp.dueFollowUp(for: waiting(followUpAt: later, made: made), now: now)
    XCTAssertNotNil(plan)
    XCTAssertNotEqual(plan?.taskId, made)
  }

  func testTheTitleNamesTheTagOnlyWhenThereIsOne() {
    XCTAssertEqual(WaitingFollowUp.title(for: "Invoice paid", waitingOn: nil), "Follow up: Invoice paid")
    XCTAssertEqual(WaitingFollowUp.title(for: "Invoice paid", waitingOn: "  "), "Follow up: Invoice paid")
    XCTAssertEqual(WaitingFollowUp.title(for: "Invoice paid", waitingOn: " Legal "), "Follow up with Legal: Invoice paid")
  }

  /// The same vector is asserted by the Android port, so both platforms make
  /// one row that sync merges rather than two.
  func testTheFollowUpIdIsDeterministicAndUUIDShaped() {
    let at = Date(timeIntervalSince1970: 1_791_291_600)  // 2026-10-06 13:00 UTC
    let id = WaitingFollowUp.followUpTaskId(sourceTaskId: "6F1C2A9E-0000-4000-8000-000000000001", followUpAt: at)
    XCTAssertEqual(id, "D2D0E044-BDD3-5ED3-95C6-C687611541D1")
    XCTAssertEqual(id, WaitingFollowUp.followUpTaskId(
      sourceTaskId: "6F1C2A9E-0000-4000-8000-000000000001", followUpAt: at.addingTimeInterval(0.4)))
    XCTAssertNotNil(UUID(uuidString: id))
    XCTAssertEqual(id, id.uppercased())
    XCTAssertEqual(Array(id)[14], "5")
  }

  func testTheLabelNamesTodayTomorrowAWeekdayOrADate() {
    XCTAssertEqual(WaitingFollowUp.label(date(2026, 10, 6, 14), now: now, calendar: calendar), "↻ Today 14:00")
    XCTAssertEqual(WaitingFollowUp.label(date(2026, 10, 7, 9), now: now, calendar: calendar), "↻ Tomorrow 09:00")
    XCTAssertEqual(WaitingFollowUp.label(date(2026, 10, 8, 14), now: now, calendar: calendar), "↻ Thu 14:00")
    XCTAssertEqual(WaitingFollowUp.label(date(2026, 10, 20, 14), now: now, calendar: calendar), "↻ 20 Oct 14:00")
    XCTAssertEqual(WaitingFollowUp.editableText(date(2026, 10, 8, 14, 5), calendar: calendar), "2026-10-08 14:05")
  }

  // MARK: - Date and time words

  private func parse(_ text: String) -> Date? {
    TaskCapture.dateTime(from: text, now: now, calendar: calendar)
  }

  func testADayAloneIsAtNine() {
    XCTAssertEqual(parse("tomorrow"), date(2026, 10, 7, 9))
    XCTAssertEqual(parse("@fri"), date(2026, 10, 9, 9))
    XCTAssertEqual(parse("3d"), date(2026, 10, 9, 9))
    XCTAssertEqual(parse("2026-10-08"), date(2026, 10, 8, 9))
  }

  func testADayAndATimeInEitherOrder() {
    XCTAssertEqual(parse("tomorrow 9am"), date(2026, 10, 7, 9))
    XCTAssertEqual(parse("2026-10-08 14:00"), date(2026, 10, 8, 14))
    XCTAssertEqual(parse("fri at 2:30pm"), date(2026, 10, 9, 14, 30))
    XCTAssertEqual(parse("3pm @thu"), date(2026, 10, 8, 15))
    XCTAssertEqual(parse("Tomorrow Noon"), date(2026, 10, 7, 12))
  }

  func testATimeAloneIsTheNextOneToCome() {
    XCTAssertEqual(parse("14:00"), date(2026, 10, 6, 14))
    XCTAssertEqual(parse("9am"), date(2026, 10, 7, 9))
    XCTAssertEqual(parse("12am"), date(2026, 10, 7, 0))
  }

  /// Today is a Tuesday: "tue 9am" has gone, so it is next Tuesday's.
  func testAWeekdayWhoseTimeHasPassedIsNextWeeks() {
    XCTAssertEqual(parse("tue 9am"), date(2026, 10, 13, 9))
    XCTAssertEqual(parse("tue 4pm"), date(2026, 10, 6, 16))
    // "today" means today, even when the time has gone: it is due at once.
    XCTAssertEqual(parse("today 9am"), date(2026, 10, 6, 9))
  }

  func testUnreadableTextIsNil() {
    for text in ["", "soon", "25:00", "13pm", "9:75", "tomorrow tomorrow", "9am 10am", "2026-02-31"] {
      XCTAssertNil(parse(text), text)
    }
  }
}
