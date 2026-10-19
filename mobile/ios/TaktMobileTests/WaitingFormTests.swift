import TaktCore
import TaktWorkspace
import XCTest
@testable import Takt

final class WaitingFormTests: XCTestCase {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    return calendar
  }

  private func date(_ text: String) -> Date {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_GB")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: text)!
  }

  // MARK: - The stepper, Android's `stepEveryDays`

  func testTheRepeatStepsADayAtATimeUpToAWeekThenAWeekAtATime() {
    XCTAssertEqual(WaitingForm.step(3, by: 1), 4)
    XCTAssertEqual(WaitingForm.step(6, by: 1), 7)
    XCTAssertEqual(WaitingForm.step(7, by: 1), 14)
    XCTAssertEqual(WaitingForm.step(14, by: 1), 21)
    XCTAssertEqual(WaitingForm.step(14, by: -1), 7)
    XCTAssertEqual(WaitingForm.step(7, by: -1), 6)
    XCTAssertEqual(WaitingForm.step(2, by: -1), 1)
  }

  func testTheRepeatStaysWithinOneToAYear() {
    XCTAssertEqual(WaitingForm.step(1, by: -1), 1)
    XCTAssertEqual(WaitingForm.step(364, by: 1), 365)
    XCTAssertEqual(WaitingForm.step(365, by: 1), 365)
  }

  // MARK: - The form

  func testTheFormStartsFromWhatIsSavedAndNoticesAChange() {
    let saved = TaskWaitingDetails(waitingOn: "Sam", followUpAt: date("2026-10-20 14:00"), followUpEveryDays: 3)
    var form = WaitingForm(saved: saved)
    XCTAssertEqual(form, WaitingForm(tag: "Sam", followUpAt: date("2026-10-20 14:00"), everyDays: 3))
    XCTAssertFalse(form.differs(from: saved))

    form.tag = "  Sam "
    XCTAssertFalse(form.differs(from: saved), "the core trims the tag")
    form.followUpAt = date("2026-10-20 14:00").addingTimeInterval(30)
    XCTAssertFalse(form.differs(from: saved), "the core keeps the time to the minute")
    form.everyDays = 4
    XCTAssertTrue(form.differs(from: saved))
  }

  func testARepeatWithoutAFollowUpTimeIsNotSaved() {
    let form = WaitingForm(tag: "Legal", followUpAt: nil, everyDays: 3)
    XCTAssertNil(form.savedEveryDays)
    XCTAssertFalse(form.differs(from: TaskWaitingDetails(waitingOn: "Legal")))
  }

  func testTheQuickChoicesAreMorningsTomorrowInThreeDaysAndNextWeek() {
    let now = date("2026-10-19 22:30")
    let choices = WaitingForm.quickChoices(now: now, calendar: calendar)
    XCTAssertEqual(choices.map(\.title), ["Tomorrow 9:00", "In 3 days", "Next week"])
    XCTAssertEqual(choices.map(\.date), [date("2026-10-20 09:00"), date("2026-10-22 09:00"), date("2026-10-26 09:00")])
    XCTAssertEqual(WaitingForm.defaultFollowUp(now: now, calendar: calendar), date("2026-10-20 09:00"))
  }

  func testTheHintSaysWhatLandsInToday() {
    XCTAssertEqual(
      WaitingForm(tag: "Sam").hint(title: "Contract signed"),
      "Files it in Waiting on. Pick a time to have a follow-up land in Today.")
    XCTAssertEqual(
      WaitingForm(tag: "Sam", followUpAt: date("2026-10-20 09:00")).hint(title: "Contract signed"),
      "If it is still waiting then, “Follow up with Sam: Contract signed” lands in Today.")
    XCTAssertEqual(
      WaitingForm(tag: "Sam", followUpAt: date("2026-10-20 09:00"), everyDays: 3).hint(title: "Contract signed"),
      "If it is still waiting then, “Follow up with Sam: Contract signed” lands in Today; once that is done, "
        + "the next lands every 3 days later, numbered #2, #3.")
  }

  // MARK: - The badge

  func testTheBadgeShowsOnlyInWaitingOnAndTheTimeOnlyWhileOpen() {
    let now = date("2026-10-19 10:00")
    let details = TaskWaitingDetails(
      waitingOn: "Sam", followUpAt: date("2026-10-20 14:00"), followUpEveryDays: 3, chase: "#2 · every 3d")
    XCTAssertEqual(
      WaitingBadge.make(details, column: "waiting-on", status: .open, now: now, calendar: calendar),
      WaitingBadge(waitingOn: "Sam", followUp: "↻ Tomorrow 14:00 · #2 · every 3d"))
    XCTAssertEqual(
      WaitingBadge.make(details, column: "waiting-on", status: .completed, now: now, calendar: calendar),
      WaitingBadge(waitingOn: "Sam", followUp: nil))
    XCTAssertNil(WaitingBadge.make(details, column: "today", status: .open, now: now, calendar: calendar))
    XCTAssertNil(WaitingBadge.make(nil, column: "waiting-on", status: .open, now: now, calendar: calendar))
    XCTAssertNil(
      WaitingBadge.make(
        TaskWaitingDetails(followUpAt: date("2026-10-20 14:00")), column: "waiting-on", status: .completed,
        now: now, calendar: calendar))
  }
}

@MainActor
final class WaitingModelTests: XCTestCase {
  func testSettingWaitingFilesTheTaskAndGivesItsRowABadgeWithTheCoresChaseLabel() throws {
    let model = try WorkspaceModel.temporary()
    let inbox = try XCTUnwrap(model.inbox)
    let task = try XCTUnwrap(model.createTask("Contract signed", listID: inbox.id))
    let followUp = Date.now.addingTimeInterval(3 * 86_400)

    XCTAssertTrue(model.perform {
      try $0.setWaiting(taskId: task.id, waitingOn: "Sam", followUpAt: followUp, everyDays: 3)
    })
    XCTAssertEqual(try model.store.kanbanColumn(for: task.id), WaitingFollowUp.waitingColumnID)
    let badge = try XCTUnwrap(model.waitingBadge(task.id))
    XCTAssertEqual(badge.waitingOn, "Sam")
    XCTAssertEqual(
      badge.followUp, WaitingFollowUp.label(WaitingForm.minute(followUp), chase: "every 3d"))

    // Cleared, it stays in Waiting on with nothing to say.
    XCTAssertTrue(model.perform { try $0.setWaiting(taskId: task.id, waitingOn: nil, followUpAt: nil, everyDays: nil) })
    XCTAssertNil(model.waitingBadge(task.id))

    // Out of Waiting on, a tag is not drawn.
    XCTAssertTrue(model.perform { try $0.setWaiting(taskId: task.id, waitingOn: "Sam", followUpAt: nil, everyDays: nil) })
    XCTAssertNotNil(model.waitingBadge(task.id))
    XCTAssertTrue(model.perform { try $0.setKanbanColumn("today", for: [task.id]) })
    XCTAssertNil(model.waitingBadge(task.id))
  }
}
