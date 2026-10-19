import Foundation
import TaktCore
import TaktWorkspace

/// Waiting on, as rows and cards show it: who a task waits on and when it
/// will be chased. The editor is the inspector's `WaitingSection`.
extension WorkspaceModel {
  /// Reads the waiting tasks and keeps those still filed in Waiting on: a
  /// follow-up task, or a task moved out of the column, shows nothing.
  func refreshWaitingDetails() {
    guard let details = try? store.waitingDetails() else { return }
    let columns = details.isEmpty ? [:] : ((try? store.boardMetadata(for: Array(details.keys)).columns) ?? [:])
    let waiting = details.filter { columns[$0.key] == WaitingFollowUp.waitingColumnID }
    if waiting != waitingDetails { waitingDetails = waiting }
  }

  /// The chips for a task's row: `Sam` and `↻ Tue 14:00 · #2 · every 3d`.
  /// Nil when it is not waiting, or names nothing and has no time.
  func waitingBadge(_ taskID: String, status: TaskStatus = .open, now: Date = .now) -> WaitingBadge? {
    guard let details = waitingDetails[taskID] else { return nil }
    return WaitingBadge.make(details, column: WaitingFollowUp.waitingColumnID, status: status, now: now)
  }
}
