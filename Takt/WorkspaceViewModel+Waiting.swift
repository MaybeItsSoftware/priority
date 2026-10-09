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
      if try store.reconcileWaitingFollowUps(now: now) {
        waitingDetailsAreStale = true
        refresh([.outline, .nextUp])
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// Rereads `waitingDetails` if anything has been written since it was last
  /// read: a local write, undo, a sync pull or another process. Pure
  /// navigation, which rebuilds the task cache too, skips it.
  func reloadWaitingDetails() {
    guard let store else { return }
    // Read before the details, so a write landing in between makes the next
    // call read again rather than keep what this one missed.
    let stamp = try? store.changeStamp()
    let key = ObjectIdentifier(store)
    if !waitingDetailsAreStale, let stamp, let last = waitingDetailsStamp,
      last.store == key, last.stamp == stamp
    {
      return
    }
    guard let details = try? store.waitingDetails() else { return }
    waitingDetailsAreStale = false
    if waitingDetails != details { waitingDetails = details }
    waitingDetailsStamp = stamp.map { (key, $0) }
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
