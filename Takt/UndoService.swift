import Foundation
import Observation

/// Performs the actual rewind for an `UndoableAction`. `UndoService` calls
/// these on the active coordinator with `isUndo: true` so the destination
/// methods know not to push a fresh entry onto the stack.
///
/// Declared as a protocol (rather than taking `AppCoordinator` directly) so
/// `UndoService` can compile against `TaktAppLogic` and be unit-tested
/// without spinning up the app shell.
@MainActor
protocol UndoActionPerforming: AnyObject {
  func deleteTask(_ task: CheckvistTask, isUndo: Bool) async
  func taskAction(_ task: CheckvistTask, endpoint: String, isUndo: Bool) async
  func updateTask(task: CheckvistTask, content: String?, due: String?, isUndo: Bool) async
}

/// Owns the single-slot undo stack and the rewind logic for the most recent
/// task mutation. Pulled out of `TaskRepository` (where the state was parked)
/// and `AppCoordinator+Undo.swift` (where the rewind lived) so undo is one
/// concept in one place.
///
/// The service holds a `weak` reference to the performer because the rewind
/// path goes back through coordinator-level mutation methods which themselves
/// push *new* entries onto this service via `record(_:)`. The `isUndo: true`
/// flag on those methods is what stops the rewind from looping.
@MainActor
@Observable
final class UndoService {
  @ObservationIgnored private weak var performer: UndoActionPerforming?

  /// The action that would be reverted by `undo()`, or nil if the stack is empty.
  var lastAction: UndoableAction?

  init(performer: UndoActionPerforming) {
    self.performer = performer
  }

  func record(_ action: UndoableAction) {
    lastAction = action
  }

  func clear() {
    lastAction = nil
  }

  func undo() async {
    guard let action = lastAction, let performer else { return }
    lastAction = nil

    switch action {
    case .add(let taskId):
      let mockTask = CheckvistTask(
        id: taskId, content: "", status: 0, due: nil, position: nil, parentId: nil, level: nil)
      await performer.deleteTask(mockTask, isUndo: true)
    case .markDone(let taskId), .invalidate(let taskId):
      let mockTask = CheckvistTask(
        id: taskId, content: "", status: 1, due: nil, position: nil, parentId: nil, level: nil)
      await performer.taskAction(mockTask, endpoint: "reopen", isUndo: true)
    case .update(let taskId, let oldContent, let oldDue):
      let mockTask = CheckvistTask(
        id: taskId, content: "", status: 0, due: nil, position: nil, parentId: nil, level: nil)
      await performer.updateTask(
        task: mockTask, content: oldContent, due: oldDue, isUndo: true)
    }
  }
}
