import Foundation
import PriorityWorkspace

/// Starting, advancing and ending a focus session. Split from
/// `WorkspaceViewModel.swift` only for size.
@MainActor
extension WorkspaceViewModel {
  /// `plannedSeconds` is the estimate committed to on the focus screen. Without
  /// one the task's own estimate is used, and failing that a default block.
  func startFocus(on task: WorkspaceTask, plannedSeconds: Int? = nil) {
    guard let store else { return }
    perform {
      activeFocusSession = try store.startFocusSession(
        taskId: task.id, plannedSeconds: plannedSeconds ?? task.estimateSeconds)
      reloadFocus()
      reloadNextUp()
      showsFocusPanel = false
      showsFocusScreen = false
      focusFloatRequest += 1
    }
  }

  /// Opens the focus screen, seeding the estimate from whatever the suggested
  /// task already knows about itself — its daily target, then its estimate.
  func presentFocusScreen() {
    // Always open at the foot of the ladder. Where you climbed to last time was
    // a judgement about that moment, not a preference to restore.
    focusLadderIndex = 0
    stagedTaskID = nil
    reloadNextUp()
    showsFocusScreen = true
  }

  /// Mirrors the plan → focus handoff: the first open Today card goes live,
  /// and the rest become its queue in the visible board order. This also works
  /// in Everything, while tasks retain their original lists and parents.
  func startFocusFromToday(plannedSeconds: Int? = nil) {
    let planned = todayTasks
    guard let store, let first = planned.first else { return }
    if activeFocusSession != nil {
      showsFocusPanel = true
      return
    }
    perform {
      let session = try store.startFocusSession(
        taskId: first.id, plannedSeconds: plannedSeconds ?? first.estimateSeconds)
      for task in planned.dropFirst() {
        try store.addToFocusQueue(
          sessionId: session.id, taskId: task.id, plannedSeconds: plannedSeconds ?? task.estimateSeconds)
      }
      activeFocusSession = session
      reloadFocus()
      reloadNextUp()
      showsFocusScreen = false
      showsFocusPanel = true
    }
  }

  func addToFocusQueue(_ task: WorkspaceTask) {
    guard let store, let session = activeFocusSession else { return }
    perform {
      try store.addToFocusQueue(sessionId: session.id, taskId: task.id)
      reloadFocus()
    }
  }

  /// Credits the time actually spent since the block started, so a daily's
  /// contribution reflects the sitting rather than the estimate.
  func completeFocusedTask(now: Date = .now) {
    guard let store, let session = activeFocusSession else { return }
    let elapsed = Int(max(0, now.timeIntervalSince(session.activeTaskStartedAt)))
    perform {
      let completion = try store.completeActiveFocusTask(
        sessionId: session.id, elapsedSeconds: elapsed, now: now)
      activeFocusSession = completion.session
      lastFocusOutcome = completion.outcome
      reloadFocus()
      reloadOutline()
      reloadDailies()
      reloadNextUp()
    }
  }

  func finishFocus() {
    guard let store, let session = activeFocusSession else { return }
    perform {
      try store.finishFocusSession(id: session.id)
      reloadFocus()
      reloadNextUp()
      showsFocusPanel = false
    }
  }
}
