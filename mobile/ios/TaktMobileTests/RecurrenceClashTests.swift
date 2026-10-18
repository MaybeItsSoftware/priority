import TaktCore
import TaktWorkspace
import XCTest
@testable import Takt

@MainActor
final class RecurrenceClashTests: XCTestCase {
  private var model: WorkspaceModel!
  private var listID: String!
  private let calendar = Calendar.current

  override func setUp() async throws {
    model = try WorkspaceModel.temporary()
    listID = try XCTUnwrap(model.inbox?.id)
  }

  private func day(_ offset: Int) -> Date {
    calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: .now))!
  }

  /// A task due today that repeats daily.
  private func dailyTask() throws -> String {
    let task = try model.store.createTask(listId: listID, title: "Water the plants", dueAt: day(0))
    var draft = TaskEditorDraft(snapshot: try model.store.taskEditorSnapshot(for: task.id))
    draft.values.recurrenceRule = "daily"
    _ = try model.store.saveTaskEditor(draft)
    return task.id
  }

  private func openTasks() throws -> [WorkspaceTask] {
    try model.store.tasks(in: listID, parentTaskId: nil)
  }

  func testMovingOntoTheNextTurnAsksAndSavesNothingUntilAnswered() throws {
    let id = try dailyTask()
    model.setDue(id, daysFromToday: 1)

    let pending = try XCTUnwrap(model.recurrenceClash)
    XCTAssertEqual(pending.clash.taskId, id)
    XCTAssertTrue(pending.title.hasPrefix("Water the plants comes round again on "))
    XCTAssertTrue(pending.message.hasSuffix("lands on that turn."))
    XCTAssertEqual(try model.store.taskEditorSnapshot(for: id).dueAt, day(0))
  }

  func testStackSavesTheMoveAlone() throws {
    let id = try dailyTask()
    model.setDue(id, daysFromToday: 1)
    try XCTUnwrap(model.recurrenceClash).resolve(.stack)

    XCTAssertNil(model.recurrenceClash)
    XCTAssertEqual(try model.store.taskEditorSnapshot(for: id).dueAt, day(1))
    XCTAssertEqual(try openTasks().count, 1)
  }

  func testKeepBothAddsAOneOffCopyOnTheSameDay() throws {
    let id = try dailyTask()
    model.setDue(id, daysFromToday: 1)
    try XCTUnwrap(model.recurrenceClash).resolve(.keepBoth)

    let tasks = try openTasks()
    XCTAssertEqual(tasks.count, 2)
    let copy = try XCTUnwrap(tasks.first { $0.id != id })
    let snapshot = try model.store.taskEditorSnapshot(for: copy.id)
    XCTAssertEqual(snapshot.dueAt, day(1))
    XCTAssertEqual(snapshot.values.recurrenceRule, "")
    XCTAssertEqual(model.undoLabel, "Keep Both")
  }

  func testCancelLeavesTheTaskWhereItWas() throws {
    let id = try dailyTask()
    model.setDue(id, daysFromToday: 1)
    try XCTUnwrap(model.recurrenceClash).resolve(.cancel)

    XCTAssertNil(model.recurrenceClash)
    XCTAssertEqual(try model.store.taskEditorSnapshot(for: id).dueAt, day(0))
    XCTAssertEqual(try openTasks().count, 1)
  }

  func testAMoveWithinTheSameTurnDoesNotAsk() throws {
    let id = try dailyTask()
    model.editValues(id) { $0.dueAt = self.calendar.date(byAdding: .hour, value: 15, to: self.day(0)) }
    XCTAssertNil(model.recurrenceClash)
  }

  func testTheInspectorAsksOverItselfAndHoldsTheDraft() throws {
    let id = try dailyTask()
    let inspector = InspectorModel(
      taskID: id, draftsURL: FileManager.default.temporaryDirectory.appendingPathComponent("drafts-\(UUID()).json"))
    inspector.load(model)
    inspector.edit(model) { $0.dueAt = self.day(2) }

    XCTAssertFalse(inspector.save(model))
    XCTAssertEqual(model.recurrenceClash?.surface, .inspector)
    XCTAssertTrue(inspector.isDirty)
    try XCTUnwrap(model.recurrenceClash).resolve(.stack)
    XCTAssertFalse(inspector.isDirty)
    XCTAssertEqual(try model.store.taskEditorSnapshot(for: id).dueAt, day(2))
  }
}
