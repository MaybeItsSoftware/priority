import Foundation
import TaktCore
import TaktWorkspace
import XCTest

final class WorkspaceWaitingTests: XCTestCase {
  private var directoryURL: URL!
  private var store: WorkspaceStore!
  private var list: TaskList!

  override func setUpWithError() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("TaktWaitingTests-\(UUID().uuidString)", isDirectory: true)
    store = try WorkspaceStore(databaseURL: directoryURL.appendingPathComponent("priority.sqlite"))
    let workspace = try store.bootstrapIfNeeded()
    list = try XCTUnwrap(store.lists(in: workspace.id).first)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directoryURL)
  }

  /// 6 October 2026, at `hour` UTC.
  private func at(_ hour: Int, _ minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: hour, minute: minute))!
  }

  private func followUps(of sourceId: String) throws -> [String] {
    try store.waitingDetails().filter { $0.value.followUpOfTaskId == sourceId }.map(\.key)
  }

  func testSettingWaitingFilesTheTaskInWaitingOnWithItsTagAndTime() throws {
    let task = try store.createTask(listId: list.id, title: "Contract signed", kanbanColumn: "today")
    try store.setWaiting(taskId: task.id, waitingOn: "  Sam ", followUpAt: at(14, 0), everyDays: nil, now: at(10))

    XCTAssertEqual(try store.kanbanColumn(for: task.id), "waiting-on")
    let details = try XCTUnwrap(store.waitingDetails()[task.id])
    XCTAssertEqual(details.waitingOn, "Sam")
    XCTAssertEqual(details.followUpAt, at(14))
    XCTAssertTrue(try followUps(of: task.id).isEmpty, "not due yet")

    _ = try store.undo()
    XCTAssertEqual(try store.kanbanColumn(for: task.id), "today")
    XCTAssertNil(try store.waitingDetails()[task.id])
  }

  func testAtItsTimeAStillWaitingTaskGetsOneFollowUpInToday() throws {
    let task = try store.createTask(listId: list.id, title: "Contract signed")
    try store.setWaiting(taskId: task.id, waitingOn: "Sam", followUpAt: at(14), everyDays: nil, now: at(10))

    XCTAssertFalse(try store.reconcileWaitingFollowUps(now: at(13, 59)))
    XCTAssertTrue(try store.reconcileWaitingFollowUps(now: at(14)))
    XCTAssertFalse(try store.reconcileWaitingFollowUps(now: at(14, 1)), "made once, not on every poll")

    let ids = try followUps(of: task.id)
    XCTAssertEqual(ids, [WaitingFollowUp.followUpTaskId(sourceTaskId: task.id, followUpAt: at(14))])
    let followUp = try XCTUnwrap(store.task(id: ids[0]))
    XCTAssertEqual(followUp.title, "Follow up with Sam: Contract signed")
    XCTAssertEqual(followUp.dueAt, at(14))
    XCTAssertEqual(followUp.listId, task.listId)
    XCTAssertEqual(try store.kanbanColumn(for: followUp.id), "today")

    // Deleting the follow-up does not bring it back: the source records it.
    try store.deleteTask(id: followUp.id)
    XCTAssertFalse(try store.reconcileWaitingFollowUps(now: at(15)))

    // A new time is a new follow-up.
    try store.setWaiting(taskId: task.id, waitingOn: "Sam", followUpAt: at(16), everyDays: nil, now: at(15))
    XCTAssertTrue(try store.reconcileWaitingFollowUps(now: at(16)))
    XCTAssertEqual(try followUps(of: task.id).count, 1)
  }

  func testATaskThatLeftWaitingBeforeItsTimeGetsNone() throws {
    let task = try store.createTask(listId: list.id, title: "Invoice paid")
    try store.setWaiting(taskId: task.id, waitingOn: nil, followUpAt: at(14), everyDays: nil, now: at(10))
    try store.setKanbanColumn("in-progress", for: task.id)
    XCTAssertFalse(try store.reconcileWaitingFollowUps(now: at(15)))

    let closed = try store.createTask(listId: list.id, title: "Parcel arrived")
    try store.setWaiting(taskId: closed.id, waitingOn: nil, followUpAt: at(14), everyDays: nil, now: at(10))
    try store.setStatus(.completed, for: closed.id)
    XCTAssertFalse(try store.reconcileWaitingFollowUps(now: at(15)))
  }

  func testAFollowUpOutlivesItsSourceLeavingWaiting() throws {
    let task = try store.createTask(listId: list.id, title: "Invoice paid")
    try store.setWaiting(taskId: task.id, waitingOn: nil, followUpAt: at(14), everyDays: nil, now: at(10))
    XCTAssertTrue(try store.reconcileWaitingFollowUps(now: at(14)))
    let id = try XCTUnwrap(followUps(of: task.id).first)
    XCTAssertEqual(try store.task(id: id)?.title, "Follow up: Invoice paid")

    try store.setStatus(.completed, for: task.id)
    XCTAssertEqual(try store.task(id: id)?.status, .open)
    XCTAssertEqual(try store.kanbanColumn(for: id), "today")
  }

  /// Set after the time has passed, the follow-up is made straight away, in
  /// the same undo step.
  func testATimeAlreadyPastMakesTheFollowUpAtOnce() throws {
    let task = try store.createTask(listId: list.id, title: "Quote back")
    try store.setWaiting(taskId: task.id, waitingOn: "Legal", followUpAt: at(9), everyDays: nil, now: at(10))
    XCTAssertEqual(try followUps(of: task.id).count, 1)
    _ = try store.undo()
    XCTAssertTrue(try followUps(of: task.id).isEmpty)
  }

  /// A repeat: doing the follow-up moves the source's time on, the next is
  /// numbered, and the card's chase says which follow-up and how often.
  func testDoingARepeatingFollowUpSetsTheNextAndNumbersIt() throws {
    let task = try store.createTask(listId: list.id, title: "Contract signed")
    try store.setWaiting(taskId: task.id, waitingOn: "Sam", followUpAt: at(14), everyDays: 3, now: at(10))
    XCTAssertEqual(try store.waitingDetails()[task.id]?.chase, "every 3d")
    XCTAssertTrue(try store.reconcileWaitingFollowUps(now: at(14)))
    let first = try XCTUnwrap(followUps(of: task.id).first)

    try store.setStatus(.completed, for: first, now: at(14))
    let next = at(14).addingTimeInterval(3 * 86_400)
    let details = try XCTUnwrap(store.waitingDetails()[task.id])
    XCTAssertEqual(details.followUpAt, next)
    XCTAssertEqual(details.followUpEveryDays, 3)
    XCTAssertEqual(details.chase, "#2 · every 3d")

    XCTAssertTrue(try store.reconcileWaitingFollowUps(now: next))
    let second = WaitingFollowUp.followUpTaskId(sourceTaskId: task.id, followUpAt: next)
    XCTAssertEqual(try store.task(id: second)?.title, "Follow up #2 with Sam: Contract signed")
    XCTAssertEqual(try store.waitingDetails()[task.id]?.chase, "#2 · every 3d")
  }
}
