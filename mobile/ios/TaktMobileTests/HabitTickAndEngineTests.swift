import TaktCore
import TaktWorkspace
import XCTest
@testable import Takt

/// Ticking a habit's task, and the two engines the app runs while it is in
/// the foreground.
@MainActor
final class HabitTickAndEngineTests: XCTestCase {
  private var model: WorkspaceModel!

  override func setUp() async throws {
    model = try WorkspaceModel.temporary()
  }

  private func isDoneToday(_ dailyID: String) throws -> Bool {
    try model.store.dailies().first { $0.daily.id == dailyID }?.isDoneToday ?? false
  }

  func testTickingAHabitsTaskLogsTodayAndLeavesItOpen() throws {
    let habit = try model.store.saveHabit(HabitDraft(title: "Stretch"))
    let completions = model.completionCount

    model.toggleComplete(habit.taskId)
    XCTAssertEqual(try model.store.task(id: habit.taskId)?.status, .open, "a habit is never finished")
    XCTAssertTrue(try isDoneToday(habit.id))
    XCTAssertEqual(model.completionCount, completions + 1)

    model.toggleComplete(habit.taskId)
    XCTAssertEqual(try model.store.task(id: habit.taskId)?.status, .open)
    XCTAssertFalse(try isDoneToday(habit.id), "a second tick takes today's back")
  }

  func testAnArchivedHabitsTaskCompletesAsAnyTask() throws {
    let habit = try model.store.saveHabit(HabitDraft(title: "Stretch"))
    try model.store.archiveDaily(taskId: habit.taskId)
    model.toggleComplete(habit.taskId)
    XCTAssertEqual(try model.store.task(id: habit.taskId)?.status, .completed)
  }

  func testAnOrdinaryTaskStillCompletes() throws {
    let inbox = try XCTUnwrap(model.inbox?.id)
    let task = try model.store.createTask(listId: inbox, title: "Plain")
    model.toggleComplete(task.id)
    XCTAssertEqual(try model.store.task(id: task.id)?.status, .completed)
  }

  func testTheEnginesMakeADueFollowUpOnceAndReReadAfterIt() throws {
    let inbox = try XCTUnwrap(model.inbox?.id)
    let task = try model.store.createTask(listId: inbox, title: "Chase Sam")
    let now = Date.now
    let chaseAt = Calendar.current.date(bySetting: .second, value: 0, of: now.addingTimeInterval(3_600)) ?? now
    try model.store.setWaiting(taskId: task.id, waitingOn: "Sam", followUpAt: chaseAt, everyDays: nil, now: now)

    XCTAssertFalse(model.runForegroundEngines(now: now), "nothing due yet")
    let revision = model.revision
    XCTAssertTrue(model.runForegroundEngines(now: chaseAt.addingTimeInterval(120)))
    XCTAssertGreaterThan(model.revision, revision, "a write by an engine re-reads what is on screen")
    XCTAssertFalse(model.runForegroundEngines(now: chaseAt.addingTimeInterval(180)), "made once")
  }
}
