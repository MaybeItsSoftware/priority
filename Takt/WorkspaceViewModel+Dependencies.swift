import Foundation
import TaktWorkspace

/// Blocked by: a task that waits on other tasks until they are done. The rule
/// — which tasks are blocked, that they sink below their siblings and are
/// never next up — is the Rust core's; the screen only greys what
/// `blockedTaskIDs` names and edits the edges.
@MainActor
extension WorkspaceViewModel {
  /// Whether `task` is open and still waits on an open task.
  func isBlocked(_ task: WorkspaceTask) -> Bool {
    task.status == .open && blockedTaskIDs.contains(task.id)
  }

  /// The finder for a task to wait on, on the selected task. Nothing for a
  /// list or no task.
  func presentBlockerFinder() {
    guard let task = selectedTask, !task.isList else { return }
    presentOverlay(.blocker(WorkspaceBlockerRequest(task: task)))
  }

  /// The tasks `task` waits on, open or done.
  func blockers(of task: WorkspaceTask) -> [WorkspaceTask] {
    (try? store?.blockers(of: task.id)) ?? []
  }

  /// The tasks waiting on `task`.
  func tasksBlocked(by task: WorkspaceTask) -> [WorkspaceTask] {
    (try? store?.tasksBlocked(by: task.id)) ?? []
  }

  /// Makes `task` wait on `blocker`, as one undo step. Returns an error
  /// message — a cycle, most likely — or nil once saved.
  @discardableResult
  func addBlocker(_ blocker: WorkspaceTask, to task: WorkspaceTask) -> String? {
    guard let store else { return "The workspace is not open." }
    var failure: String?
    perform {
      do {
        try store.addBlocker(blocker.id, to: task.id)
      } catch {
        failure = error.localizedDescription
        throw error
      }
      // The blocked task sinks below its siblings, and leaves next up.
      refresh([.outline, .nextUp])
    }
    return failure
  }

  func removeBlocker(_ blocker: WorkspaceTask, from task: WorkspaceTask) {
    guard let store else { return }
    perform {
      try store.removeBlocker(blocker.id, from: task.id)
      refresh([.outline, .nextUp])
    }
  }
}
