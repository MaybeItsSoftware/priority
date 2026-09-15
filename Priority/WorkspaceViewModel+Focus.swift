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

  /// Starts on whatever the ranker currently suggests, with the estimate shown
  /// on the focus screen.
  func startFocusOnNextUp() {
    guard let task = nextUpTask() else { return }
    startFocus(on: task, plannedSeconds: max(1, focusEstimateMinutes) * 60)
  }

  /// Opens the focus screen, seeding the estimate from whatever the suggested
  /// task already knows about itself — its daily target, then its estimate.
  func presentFocusScreen() {
    reloadNextUp()
    if let task = nextUpTask() {
      let seconds = dailyItem(for: task)?.daily.targetSeconds ?? task.estimateSeconds
      focusEstimateMinutes = seconds.map { max(1, $0 / 60) } ?? 25
    }
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
    let elapsed = Int(max(0, now.timeIntervalSince(session.startedAt)))
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
