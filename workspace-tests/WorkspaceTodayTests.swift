import Foundation
import TaktCore
import TaktWorkspace
import XCTest

/// A task typed with its details, and a day planned and arranged by hand.
final class WorkspaceTodayTests: XCTestCase {
  private var directory: URL!
  private var store: WorkspaceStore!
  private var workspaceID: String!
  private var work: TaskList!
  private var home: TaskList!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("TaktTodayTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    store = try WorkspaceStore(databaseURL: directory.appendingPathComponent("priority.sqlite"))
    workspaceID = try store.bootstrapIfNeeded().id
    work = try store.createList(workspaceId: workspaceID, name: "Work")
    home = try store.createList(workspaceId: workspaceID, name: "Home")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func plannedOrder(now: Date = .now) throws -> [String] {
    try store.nextUpSnapshot(workspaceId: workspaceID, context: FocusContext(), runningID: nil, now: now)
      .todayPlan.filter { $0.reason == .planned }.map(\.id)
  }

  // MARK: - Details typed with the title

  func testATypedTaskCarriesItsDetails() throws {
    let due = Calendar.current.startOfDay(for: .now)
    let task = try store.createTask(
      listId: work.id, title: "Write notes", dueAt: due, estimateSeconds: 45 * 60,
      tags: ["work", " Work ", "q4"], priority: 2)

    XCTAssertEqual(task.dueAt, due)
    XCTAssertEqual(task.estimateSeconds, 45 * 60)
    let metadata = try store.taskEditorMetadata(for: task.id)
    XCTAssertEqual(metadata.tags, ["work", "q4"])
    XCTAssertEqual(metadata.priority, 2)
  }

  func testDetailsOutOfRangeAreDropped() throws {
    let task = try store.createTask(listId: work.id, title: "Odd", estimateSeconds: 0, priority: 7)
    XCTAssertNil(task.estimateSeconds)
    XCTAssertNil(try store.taskEditorMetadata(for: task.id).priority)
  }

  /// One undo takes back the task and everything typed with it, rather than
  /// peeling the estimate off first.
  func testATypedTaskIsOneUndoStep() throws {
    let task = try store.createTask(
      listId: work.id, title: "Write notes", kanbanColumn: NextUpSelector.todayColumnID,
      estimateSeconds: 600, tags: ["work"])
    XCTAssertEqual(try store.undo(), "New Task")
    XCTAssertNil(try store.task(id: task.id))
  }

  // MARK: - Planning the day

  func testPlanningPutsATaskOnTodayAndTakingItOffRemovesIt() throws {
    let task = try store.createTask(listId: work.id, title: "Report")
    XCTAssertEqual(try plannedOrder(), [])

    try store.setPlannedForToday(true, taskIds: [task.id])
    XCTAssertEqual(try plannedOrder(), [task.id])
    XCTAssertEqual(try store.kanbanColumn(for: task.id), NextUpSelector.todayColumnID)

    try store.setPlannedForToday(false, taskIds: [task.id])
    XCTAssertEqual(try plannedOrder(), [])
    XCTAssertNil(try store.kanbanColumn(for: task.id))
  }

  func testPlanningWhatIsAlreadyPlannedIsNotAnUndoStep() throws {
    let task = try store.createTask(
      listId: work.id, title: "Report", kanbanColumn: NextUpSelector.todayColumnID)
    try store.setPlannedForToday(true, taskIds: [task.id])
    XCTAssertEqual(try store.undoableLabel(), "New Task")
  }

  /// The day's order spans lists, which the lists' own orders cannot say.
  func testArrangingTheDayOrdersItAcrossLists() throws {
    let report = try store.createTask(listId: work.id, title: "Report")
    let laundry = try store.createTask(listId: home.id, title: "Laundry")
    let email = try store.createTask(listId: work.id, title: "Email")
    try store.setPlannedForToday(true, taskIds: [report.id, laundry.id, email.id])

    try store.arrangeDay(orderedTaskIds: [email.id, laundry.id, report.id])
    XCTAssertEqual(try plannedOrder(), [email.id, laundry.id, report.id])

    XCTAssertEqual(try store.undo(), "Reorder Today")
    XCTAssertNotEqual(try plannedOrder().first, email.id)
  }

  /// A task taken off today loses its place, so it does not come back to a
  /// pinned rung of the focus ladder nobody set on purpose.
  func testTakingATaskOffTodayDropsItsPlace() throws {
    let report = try store.createTask(listId: work.id, title: "Report")
    let email = try store.createTask(listId: work.id, title: "Email")
    try store.setPlannedForToday(true, taskIds: [report.id, email.id])
    try store.arrangeDay(orderedTaskIds: [email.id, report.id])

    try store.setPlannedForToday(false, taskIds: [email.id])
    XCTAssertEqual(try plannedOrder(), [report.id])
    try store.setPlannedForToday(true, taskIds: [email.id])
    // Back at the end of the day, behind the task that kept its place.
    XCTAssertEqual(try plannedOrder(), [report.id, email.id])
  }
}
