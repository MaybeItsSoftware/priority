import Foundation
import TaktCore
import TaktWorkspace
import XCTest

/// Committing to a task periodically: the store's face of
/// `core/src/commitments.rs`, which has the full rule tests.
final class WorkspaceCommitmentTests: XCTestCase {
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
      .appendingPathComponent("TaktCommitmentTests-\(UUID().uuidString)", isDirectory: true)
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

  func testCommittingMakesALinkedSubtaskThatAppearsInDailiesOnItsDays() throws {
    let thesis = try store.createTask(listId: list.id, title: "Thesis")
    XCTAssertEqual(WorkspaceCommitment.defaultTitle(forTaskTitle: thesis.title), "Work on Thesis")

    let subtaskId = try store.saveCommitment(
      taskId: thesis.id, draft: WorkspaceCommitmentDraft(title: "Write 500 words", rule: "every friday"),
      now: day(5), calendar: calendar)
    let subtask = try XCTUnwrap(store.task(id: subtaskId))
    XCTAssertEqual(subtask.parentTaskId, thesis.id)
    XCTAssertEqual(subtask.title, "Write 500 words")

    let commitments = try store.commitments(forTaskId: thesis.id)
    XCTAssertEqual(commitments.map(\.taskId), [subtaskId])
    XCTAssertEqual(commitments.first?.rule, "every friday")
    XCTAssertEqual(commitments.first?.weekdays, [6])
    XCTAssertEqual(try store.commitment(taskId: subtaskId), commitments.first)
    XCTAssertEqual(try store.allCommitments(), commitments)

    // Not on Monday; on Friday.
    XCTAssertFalse(try store.dailies(on: day(5), calendar: calendar).contains { $0.task.id == subtaskId })
    XCTAssertTrue(try store.dailies(on: day(9), calendar: calendar).contains { $0.task.id == subtaskId })
  }

  func testALastDayEndsItAndCompletingTheTaskEndsItToo() throws {
    let thesis = try store.createTask(listId: list.id, title: "Thesis")
    let lastDay = day(7)
    let expiry = WorkspaceCommitment.expiry(forLastDay: lastDay, calendar: calendar)
    XCTAssertEqual(expiry, calendar.date(from: DateComponents(year: 2026, month: 10, day: 8)))
    let subtaskId = try store.saveCommitment(
      taskId: thesis.id, draft: WorkspaceCommitmentDraft(title: "Work on Thesis", expiresAt: expiry),
      now: day(5), calendar: calendar)
    let commitment = try XCTUnwrap(store.commitment(taskId: subtaskId))
    XCTAssertEqual(commitment.lastDay(calendar: calendar), calendar.startOfDay(for: lastDay))
    XCTAssertTrue(try store.dailies(on: day(7), calendar: calendar).contains { $0.task.id == subtaskId })
    XCTAssertFalse(try store.dailies(on: day(8), calendar: calendar).contains { $0.task.id == subtaskId })

    try store.setStatus(.completed, for: thesis.id, now: day(6))
    XCTAssertTrue(try store.commitments(forTaskId: thesis.id).isEmpty)
    XCTAssertEqual(try store.task(id: subtaskId)?.status, .completed)
  }

  func testEditingRewritesInPlaceAndStoppingKeepsTheTask() throws {
    let thesis = try store.createTask(listId: list.id, title: "Thesis")
    let subtaskId = try store.saveCommitment(
      taskId: thesis.id, draft: WorkspaceCommitmentDraft(title: "Work on Thesis"), now: day(5), calendar: calendar)
    let edited = try store.saveCommitment(
      taskId: thesis.id, draft: WorkspaceCommitmentDraft(title: "Read", rule: "mon, wed, fri"),
      commitmentTaskId: subtaskId, now: day(5), calendar: calendar)
    XCTAssertEqual(edited, subtaskId)
    XCTAssertEqual(try store.commitment(taskId: subtaskId)?.rule, "mon, wed, fri")
    XCTAssertEqual(try store.task(id: subtaskId)?.title, "Read")

    try store.stopCommitment(taskId: subtaskId, now: day(6), calendar: calendar)
    XCTAssertNil(try store.commitment(taskId: subtaskId))
    XCTAssertEqual(try store.task(id: thesis.id)?.status, .open)
  }

  func testAMissedAppearanceVanishesByDefaultAndStacksWhenAskedTo() throws {
    let thesis = try store.createTask(listId: list.id, title: "Thesis")
    let vanishing = try store.saveCommitment(
      taskId: thesis.id, draft: WorkspaceCommitmentDraft(title: "Read", rule: "mon, wed, fri"),
      now: day(5), calendar: calendar)
    let stacking = try store.saveCommitment(
      taskId: thesis.id, draft: WorkspaceCommitmentDraft(title: "Write", rule: "mon, wed, fri", stacksMissed: true),
      now: day(5), calendar: calendar)
    XCTAssertEqual(try store.commitment(taskId: vanishing)?.stacksMissed, false)
    XCTAssertEqual(try store.commitment(taskId: stacking)?.stacksMissed, true)

    // Monday is missed by both. On Tuesday only the stacking one still shows.
    let tuesday = try store.dailies(on: day(6), calendar: calendar).map(\.task.id)
    XCTAssertFalse(tuesday.contains(vanishing))
    XCTAssertTrue(tuesday.contains(stacking))
    XCTAssertEqual(try store.commitment(taskId: vanishing, now: day(6), calendar: calendar)?.missed, 0)
    XCTAssertEqual(try store.commitment(taskId: stacking, now: day(6), calendar: calendar)?.missed, 1)
    XCTAssertEqual(WorkspaceCommitment.carriesMissedDays("every friday"), true)
    XCTAssertEqual(WorkspaceCommitment.carriesMissedDays("weekdays"), false)
  }

  func testAScheduleTheSyntaxCannotReadIsRefusedWithItsMessage() throws {
    XCTAssertTrue(WorkspaceCommitment.isSchedule("every 2 weeks"))
    XCTAssertEqual(WorkspaceCommitment.normalizedRule("Every Tue and Thu"), "tue, thu")
    XCTAssertFalse(WorkspaceCommitment.isSchedule("now and then"))
    let thesis = try store.createTask(listId: list.id, title: "Thesis")
    XCTAssertThrowsError(
      try store.saveCommitment(
        taskId: thesis.id, draft: WorkspaceCommitmentDraft(title: "Work", rule: "now and then"),
        now: day(5), calendar: calendar)
    ) { error in
      XCTAssertEqual(error as? WorkspaceStoreError, .invalidRecurrence("now and then"))
    }
  }
}
