import Foundation
import TaktCore
import TaktWorkspace

/// Waiting on: the tag and follow-up time on a waiting task, and the engine
/// that turns a follow-up time into a task in Today. See `WaitingFollowUp`.
@MainActor
extension WorkspaceViewModel {
  /// How often the poll looks for a follow-up that has come due. The field
  /// takes whole minutes, so a follow-up lands within a quarter of one.
  static let followUpCheckInterval: TimeInterval = 15

  /// Run from the external-write poll, which ticks once a second. Makes any
  /// follow-up that has come due, and reloads what shows it.
  func checkForDueFollowUps(now: Date = .now) {
    guard let store, now >= nextFollowUpCheck else { return }
    nextFollowUpCheck = now.addingTimeInterval(Self.followUpCheckInterval)
    do {
      if try store.reconcileWaitingFollowUps(now: now) { refresh([.outline, .nextUp]) }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func reloadWaitingDetails() {
    guard let store, let details = try? store.waitingDetails() else { return }
    if waitingDetails != details { waitingDetails = details }
  }

  func waiting(for task: WorkspaceTask) -> TaskWaitingDetails? {
    waitingDetails[task.id]
  }

  /// The Waiting on form, on the selected task. Nothing for a list or no task.
  func presentWaitingForm() {
    guard let task = selectedTask, !task.isList else { return }
    presentOverlay(.waiting(WorkspaceWaitingRequest(task: task, details: waitingDetails[task.id])))
  }

  /// Sets what `task` waits on and when to follow up, filing it in Waiting
  /// on. Returns an error message, or nil once saved.
  @discardableResult
  func setWaiting(_ task: WorkspaceTask, waitingOn: String?, followUpAt: Date?) -> String? {
    guard let store else { return "The workspace is not open." }
    var failure: String?
    perform {
      do {
        try store.setWaiting(taskId: task.id, waitingOn: waitingOn, followUpAt: followUpAt)
      } catch {
        failure = error.localizedDescription
        throw error
      }
      refresh([.outline, .nextUp])
    }
    return failure
  }
}
