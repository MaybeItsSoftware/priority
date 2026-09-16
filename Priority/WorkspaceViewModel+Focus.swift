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

  /// A finished block, held between pressing Done and saying how it went.
  ///
  /// The elapsed time is captured here rather than read again on confirmation:
  /// the seconds that count are the ones spent working, not the ones spent
  /// deciding what the work was worth.
  struct PendingFocusCompletion: Identifiable, Equatable {
    let sessionID: String
    let taskID: String
    let title: String
    let seconds: Int

    var id: String { "\(sessionID)/\(taskID)" }
    var minutes: Double { FocusPoints.minutes(seconds: seconds) }
  }

  /// Stops the clock and asks how the block went. Nothing is written yet — the
  /// task stays open and the queue stays put until the prompt is answered.
  func requestFocusCompletion(now: Date = .now) {
    guard let session = activeFocusSession, let task = activeFocusTask else { return }
    pendingFocusCompletion = PendingFocusCompletion(
      sessionID: session.id, taskID: task.id, title: task.title,
      seconds: Int(max(0, now.timeIntervalSince(session.activeTaskStartedAt))))
    // The prompt is a sheet, and so is the panel; only one of them can be on
    // screen. Remembering which surface asked lets the panel come back.
    resumesFocusPanel = showsFocusPanel
    showsFocusPanel = false
  }

  /// Drops the prompt and leaves the block running. The time carries on from
  /// where it was, because the block never actually ended.
  func cancelFocusCompletion() {
    pendingFocusCompletion = nil
    restoreFocusPanelIfItWasOpen()
  }

  /// Credits the time actually spent, so a daily's contribution reflects the
  /// sitting rather than the estimate, and scores it by the multiplier given.
  func confirmFocusCompletion(multiplier: Double) {
    guard let store, let pending = pendingFocusCompletion else { return }
    pendingFocusCompletion = nil
    perform {
      let completion = try store.completeActiveFocusTask(
        sessionId: pending.sessionID, elapsedSeconds: pending.seconds, qualityMultiplier: multiplier)
      activeFocusSession = completion.session
      lastFocusOutcome = completion.outcome
      lastFocusAward = completion.award
      reloadFocus()
      reloadOutline()
      reloadDailies()
      reloadNextUp()
      restoreFocusPanelIfItWasOpen()
    }
  }

  private func restoreFocusPanelIfItWasOpen() {
    defer { resumesFocusPanel = false }
    guard resumesFocusPanel, activeFocusSession?.activeTaskId != nil else { return }
    showsFocusPanel = true
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
