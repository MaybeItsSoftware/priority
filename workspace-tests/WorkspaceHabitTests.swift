import Foundation
import TaktCore
import TaktWorkspace
import XCTest

final class WorkspaceHabitTests: XCTestCase {
  private var directoryURL: URL!
  private var store: WorkspaceStore!
  private var list: TaskList!
  private var calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  override func setUpWithError() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("TaktHabitTests-\(UUID().uuidString)", isDirectory: true)
    store = try WorkspaceStore(databaseURL: directoryURL.appendingPathComponent("priority.sqlite"))
    let workspace = try store.bootstrapIfNeeded()
    list = try XCTUnwrap(store.lists(in: workspace.id).first)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directoryURL)
  }

  /// 2026-10-05 is a Monday.
  private func day(_ value: Int, hour: Int = 12) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 10, day: value, hour: hour))!
  }

  func testTheFormOpensOnTheSelectedTaskAsASourceOrOnItsHabit() throws {
    let goal = try store.createTask(listId: list.id, title: "Learn drums")
    let fresh = try store.habitFormContext(forTaskId: goal.id)
    XCTAssertNil(fresh.habitTaskId)
    XCTAssertEqual(fresh.draft.sourceTaskId, goal.id)
    XCTAssertEqual(fresh.draft.expiry, .whenSourceCompleted)
    XCTAssertEqual(fresh.sourceTitle, "Learn drums")

    let standalone = try store.habitFormContext(forTaskId: nil)
    XCTAssertEqual(standalone.draft.expiry, .never)

    var draft = fresh.draft
    draft.title = "Practise drums"
    draft.frequency = .weekdays([2, 4, 6])
    draft.estimateSeconds = 1_800
    draft.placement = .thisWeek
    draft.dropsAtDayEnd = false
    let daily = try store.saveHabit(draft, now: day(5), calendar: calendar)

    let editing = try store.habitFormContext(forTaskId: daily.taskId)
    XCTAssertEqual(editing.habitTaskId, daily.taskId)
    XCTAssertEqual(editing.draft, draft)
    XCTAssertEqual(editing.sourceTitle, "Learn drums")
    XCTAssertEqual(try store.task(id: daily.taskId)?.estimateSeconds, 1_800)
  }

  func testADueHabitLandsInItsColumnAndLeavesItOnceTicked() throws {
    let daily = try store.saveHabit(
      HabitDraft(title: "Stretch", placement: .thisWeek), now: day(5), calendar: calendar)
    XCTAssertEqual(try store.kanbanColumn(for: daily.taskId), "this-week")

    try store.logContribution(dailyId: daily.id, now: day(5), calendar: calendar)
    XCTAssertTrue(try store.reconcileHabits(now: day(5, hour: 13), calendar: calendar))
    XCTAssertNil(try store.kanbanColumn(for: daily.taskId))

    XCTAssertTrue(try store.reconcileHabits(now: day(6), calendar: calendar))
    XCTAssertEqual(try store.kanbanColumn(for: daily.taskId), "this-week")
    XCTAssertEqual(try store.task(id: daily.taskId)?.status, .open)
  }

  func testAMissedAppearanceIsDroppedOrCarried() throws {
    let dropped = try store.saveHabit(
      HabitDraft(title: "Weekly review", frequency: .weekly, dropsAtDayEnd: true),
      now: day(5), calendar: calendar)
    let carried = try store.saveHabit(
      HabitDraft(title: "Call home", frequency: .weekly, dropsAtDayEnd: false, placement: .waiting),
      now: day(5), calendar: calendar)

    try store.reconcileHabits(now: day(7), calendar: calendar)

    XCTAssertNil(try store.kanbanColumn(for: dropped.taskId))
    XCTAssertEqual(try store.kanbanColumn(for: carried.taskId), "waiting-on")
    XCTAssertEqual(try store.dailies(on: day(7), calendar: calendar).map(\.daily.id), [carried.id])
  }

  func testCompletingTheSourceTaskEndsTheHabitAndUndoBringsItBack() throws {
    let goal = try store.createTask(listId: list.id, title: "Learn drums")
    var draft = try store.habitFormContext(forTaskId: goal.id).draft
    draft.title = "Practise drums"
    let daily = try store.saveHabit(draft, now: .now)
    XCTAssertEqual(try store.kanbanColumn(for: daily.taskId), "today")

    try store.setStatus(.completed, for: goal.id)

    XCTAssertNil(try store.daily(forTaskId: daily.taskId), "the habit ended with its source")
    XCTAssertNil(try store.kanbanColumn(for: daily.taskId))

    XCTAssertEqual(try store.undo(), "Change Status")
    XCTAssertEqual(try store.daily(forTaskId: daily.taskId)?.id, daily.id)
  }

  func testADateExpiryArchivesTheHabitOnThatDay() throws {
    let daily = try store.saveHabit(
      HabitDraft(title: "Course reading", expiry: .on(day(8))), now: day(5), calendar: calendar)

    try store.reconcileHabits(now: day(7), calendar: calendar)
    XCTAssertNotNil(try store.daily(forTaskId: daily.taskId))

    try store.reconcileHabits(now: day(8), calendar: calendar)
    XCTAssertNil(try store.daily(forTaskId: daily.taskId))
    XCTAssertNil(try store.kanbanColumn(for: daily.taskId))
  }

  func testACardMovedByHandIsLeftWhereItWasPut() throws {
    let daily = try store.saveHabit(HabitDraft(title: "Stretch"), now: day(5), calendar: calendar)
    try store.setKanbanColumn("in-progress", for: daily.taskId)

    XCTAssertFalse(try store.reconcileHabits(now: day(6), calendar: calendar))
    XCTAssertEqual(try store.kanbanColumn(for: daily.taskId), "in-progress")
  }
}
