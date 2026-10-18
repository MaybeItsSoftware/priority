import Foundation
import TaktCore
import TaktWorkspace

/// What the focus panel reads and does beyond the day: a list's outline,
/// read without moving the main window to it, and the panel's start.
@MainActor
extension WorkspaceViewModel {
  /// A list's outline as the window's outline pane would draw it — the same
  /// read, the same shaping, completed and buried tasks hidden or shown as
  /// the window has them — for the panel. The read is the scope cache's, so
  /// a list already drawn in the window, or read since the last write, costs
  /// nothing. Folds are the caller's to apply (`TaskOutlineFolding.visible`).
  func panelOutline(for destination: QuickCaptureDestination) -> [TaskOutlineItem] {
    guard let store, let list = lists.first(where: { $0.id == destination.listID }) else { return [] }
    let scope = WorkspaceScope.list(list.id)
    do {
      try ensureScopeRead(scope, store: store)
    } catch {
      errorMessage = error.localizedDescription
      return []
    }
    let options = WorkspaceScopeShapeOptions(
      scopeTaskID: destination.parentTaskID, registeredRootTaskID: list.visibleRootTaskId,
      hidesCompletedTasks: hidesCompletedTasks, hidesLaterTasks: hidesLaterTasks)
    return scopeCache.outline(for: scope, options: options, now: Date())?.items ?? []
  }

  /// A list or nested list the panel can show, by id: a list's, or the task
  /// a nested list is made of.
  func panelDestination(id: String) -> QuickCaptureDestination? {
    quickCaptureDestinations.first { $0.id == id }
  }

  /// Starting from a panel row: the running task finishes, a block already
  /// running queues it, and otherwise it starts at once, for as long as its
  /// own estimate says — pressing play is the answer to whether it is time.
  func startOrQueueFocus(on task: WorkspaceTask, from surface: FocusCompletionSurface) {
    if task.id == activeFocusSession?.activeTaskId {
      requestFocusCompletion(from: surface)
    } else if activeFocusSession != nil {
      addToFocusQueue(task)
    } else {
      startFocus(on: task, override: true)
    }
  }
}
