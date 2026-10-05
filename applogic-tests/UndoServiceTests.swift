import XCTest

@testable import TaktAppLogic

@MainActor
final class UndoServiceTests: XCTestCase {
  private var performer: FakeUndoPerformer!
  private var service: UndoService!

  override func setUp() async throws {
    try await super.setUp()
    performer = FakeUndoPerformer()
    service = UndoService(performer: performer)
  }

  // MARK: Stack state

  func testInitialStateHasNoLastAction() {
    XCTAssertNil(service.lastAction)
  }

  func testRecordSetsLastAction() {
    service.record(.add(taskId: 7))
    if case .add(let taskId) = service.lastAction {
      XCTAssertEqual(taskId, 7)
    } else {
      XCTFail("Expected .add(7), got \(String(describing: service.lastAction))")
    }
  }

  func testRecordOverwritesPreviousAction() {
    service.record(.add(taskId: 1))
    service.record(.markDone(taskId: 2))
    if case .markDone(let taskId) = service.lastAction {
      XCTAssertEqual(taskId, 2)
    } else {
      XCTFail("Expected .markDone(2), got \(String(describing: service.lastAction))")
    }
  }

  func testClearEmptiesStack() {
    service.record(.add(taskId: 1))
    service.clear()
    XCTAssertNil(service.lastAction)
  }

  // MARK: Rewind dispatch

  func testUndoOnEmptyStackIsNoop() async {
    await service.undo()
    XCTAssertEqual(performer.deleteCalls.count, 0)
    XCTAssertEqual(performer.taskActionCalls.count, 0)
    XCTAssertEqual(performer.updateCalls.count, 0)
  }

  func testUndoAddDispatchesDeleteWithIsUndoFlag() async {
    service.record(.add(taskId: 42))

    await service.undo()

    XCTAssertEqual(performer.deleteCalls.count, 1)
    XCTAssertEqual(performer.deleteCalls.first?.taskId, 42)
    XCTAssertTrue(performer.deleteCalls.first?.isUndo ?? false)
    XCTAssertNil(service.lastAction, "Stack should be cleared once rewind dispatches")
  }

  func testUndoMarkDoneDispatchesReopen() async {
    service.record(.markDone(taskId: 9))

    await service.undo()

    XCTAssertEqual(performer.taskActionCalls.count, 1)
    XCTAssertEqual(performer.taskActionCalls.first?.taskId, 9)
    XCTAssertEqual(performer.taskActionCalls.first?.endpoint, "reopen")
    XCTAssertTrue(performer.taskActionCalls.first?.isUndo ?? false)
  }

  func testUndoInvalidateDispatchesReopen() async {
    service.record(.invalidate(taskId: 11))

    await service.undo()

    XCTAssertEqual(performer.taskActionCalls.count, 1)
    XCTAssertEqual(performer.taskActionCalls.first?.taskId, 11)
    XCTAssertEqual(performer.taskActionCalls.first?.endpoint, "reopen")
  }

  func testUndoUpdateRestoresPreviousContentAndDue() async {
    service.record(.update(taskId: 3, oldContent: "before", oldDue: "2026-05-01"))

    await service.undo()

    XCTAssertEqual(performer.updateCalls.count, 1)
    let call = performer.updateCalls.first
    XCTAssertEqual(call?.taskId, 3)
    XCTAssertEqual(call?.content, "before")
    XCTAssertEqual(call?.due, "2026-05-01")
    XCTAssertTrue(call?.isUndo ?? false)
  }

  func testUndoUpdatePreservesNilDue() async {
    service.record(.update(taskId: 3, oldContent: "before", oldDue: nil))

    await service.undo()

    XCTAssertNil(performer.updateCalls.first?.due)
  }

}

// MARK: - Fake performer

@MainActor
final class FakeUndoPerformer: UndoActionPerforming {
  struct DeleteCall { let taskId: Int; let isUndo: Bool }
  struct TaskActionCall { let taskId: Int; let endpoint: String; let isUndo: Bool }
  struct UpdateCall {
    let taskId: Int
    let content: String?
    let due: String?
    let isUndo: Bool
  }

  private(set) var deleteCalls: [DeleteCall] = []
  private(set) var taskActionCalls: [TaskActionCall] = []
  private(set) var updateCalls: [UpdateCall] = []

  func deleteTask(_ task: CheckvistTask, isUndo: Bool) async {
    deleteCalls.append(DeleteCall(taskId: task.id, isUndo: isUndo))
  }

  func taskAction(_ task: CheckvistTask, endpoint: String, isUndo: Bool) async {
    taskActionCalls.append(TaskActionCall(taskId: task.id, endpoint: endpoint, isUndo: isUndo))
  }

  func updateTask(task: CheckvistTask, content: String?, due: String?, isUndo: Bool) async {
    updateCalls.append(
      UpdateCall(taskId: task.id, content: content, due: due, isUndo: isUndo)
    )
  }
}
