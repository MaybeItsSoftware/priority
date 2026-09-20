import Foundation
import PriorityWorkspace
import PriorityCore

/// Starting, advancing and ending a focus session. Split from
/// `WorkspaceViewModel.swift` only for size.
@MainActor
extension WorkspaceViewModel {
  /// `plannedSeconds` is the estimate committed to on the focus screen. Without
  /// one the task's own estimate is used, and failing that a default block.
  func startFocus(on task: WorkspaceTask, plannedSeconds: Int? = nil, automatic: Bool = false, override: Bool = false) {
    guard !task.isList else { openItemList(task); return }
    guard let store else { return }
    perform {
      let now = Date.now
      let candidate = try store.nextUpCandidates(now: now).first { $0.id == task.id }
      let reasons = candidate.map { TaskAvailabilityPolicy.reasons(for: $0, context: effectiveFocusContext, now: now) }
      let requested = plannedSeconds ?? candidate.map { TaskAvailabilityPolicy.suggestedSeconds(for: $0, context: effectiveFocusContext, now: now) } ?? 1500
      let window = effectiveFocusContext.endsAt.map { max(0, Int($0.timeIntervalSince(now))) } ?? Int.max
      let planned = automatic ? min(requested, window) : requested
      var explanations = reasons?.map { unavailableDescription($0) } ?? ["This task is not currently available for automatic focus."]
      if let end = effectiveFocusContext.endsAt, Double(planned) > end.timeIntervalSince(now) {
        explanations.append("The planned block exceeds your available time.")
      }
      if let candidate, planned < max(60, candidate.minimumBlockSeconds ?? 60) ||
        (candidate.requiresSingleSitting && planned < (candidate.remainingSeconds ?? Int.max)) {
        explanations.append("The block is shorter than this task needs.")
      }
      if !override && !explanations.isEmpty {
        if automatic {
          errorMessage = explanations.joined(separator: "\n")
          reloadNextUp()
        } else {
          focusStartOverride = FocusStartOverride(task: task, plannedSeconds: planned, explanation: explanations.joined(separator: "\n"))
        }
        return
      }
      allowsQueueResume = true
      activeFocusSession = try store.startFocusSession(
        taskId: task.id, plannedSeconds: planned, context: effectiveFocusContext, overrideAvailability: override)
      stagedTaskID = nil
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
    showsTimelineScreen = false
    showsFocusScreen = true
  }

  /// Opens the timeline over the main pane, the way focus mode does.
  ///
  /// It is a mode rather than a sheet for the same reason focus is: reading
  /// back a day's work means comparing what you meant to do with what you
  /// actually did, and a panel floating over the board gives you a slot the
  /// size of a dialog to do that in.
  func presentTimelineScreen() {
    showsFocusPanel = false
    showsFocusScreen = false
    focusHistoryDate = min(focusHistoryDate, .now)
    reloadFocus()
    showsTimelineScreen = true
  }

  func dismissTimelineScreen() {
    showsTimelineScreen = false
  }

  /// Steps the day the timeline is showing. Never past today: the future holds
  /// no logged work, so a day ahead is an empty screen with nothing to say.
  /// Reloading is left to the screen's `onChange`, which the date picker needs
  /// anyway.
  func moveTimelineDay(by days: Int) {
    guard let date = Calendar.current.date(byAdding: .day, value: days, to: focusHistoryDate) else { return }
    focusHistoryDate = min(date, .now)
  }

  func showTimelineToday() {
    focusHistoryDate = .now
  }

  var timelineShowsToday: Bool {
    Calendar.current.isDateInToday(focusHistoryDate)
  }

  /// Mirrors the plan → focus handoff: the first open Today card goes live,
  /// and the rest become its queue in the visible board order. This also works
  /// in Everything, while tasks retain their original lists and parents.
  func startFocusFromToday(plannedSeconds: Int? = nil) {
    guard let store else { return }
    if activeFocusSession != nil { showsFocusPanel = true; return }
    reloadNextUp()
    let available = Set(focusLadder.map(\.id))
    let planned = todayTasks.filter { available.contains($0.id) }
    guard let first = planned.first else { errorMessage = "No Today task is available in this context and time window."; return }
    if activeFocusSession != nil {
      showsFocusPanel = true
      return
    }
    perform {
      let session = try store.startFocusSession(
        taskId: first.id, plannedSeconds: plannedSeconds ?? suggestedFocusSeconds(for: first.id), context: effectiveFocusContext)
      for task in planned.dropFirst() {
        try store.addToFocusQueue(
          sessionId: session.id, taskId: task.id, plannedSeconds: plannedSeconds ?? suggestedFocusSeconds(for: task.id))
      }
      allowsQueueResume = true
      activeFocusSession = session
      reloadFocus()
      reloadNextUp()
      showsFocusScreen = false
      showsFocusPanel = true
    }
  }

  func addToFocusQueue(_ task: WorkspaceTask) {
    guard !task.isList else { return }
    guard let store, let session = activeFocusSession else { return }
    perform {
      try store.addToFocusQueue(sessionId: session.id, taskId: task.id)
      allowsQueueResume = true
      reloadFocus()
      reloadNextUp()
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
    let completeTask: Bool
    let blockID: String?
    let wasPaused: Bool

    var id: String { "\(sessionID)/\(taskID)" }
    var minutes: Double { FocusPoints.minutes(seconds: seconds) }
  }

  /// Pauses the clock and asks how the block went. Crediting and queue
  /// advancement wait until the prompt is answered.
  func requestFocusCompletion(now: Date = .now, completeTask: Bool = true) {
    synchroniseFocusClock(now: now)
    guard pendingFocusCompletion == nil, let session = activeFocusSession, let task = activeFocusTask else { return }
    pendingFocusCompletion = PendingFocusCompletion(
      sessionID: session.id, taskID: task.id, title: task.title,
      seconds: session.elapsedSeconds(now: now), completeTask: completeTask,
      blockID: session.activeBlockId, wasPaused: session.pausedAt != nil)
    perform { try store?.pauseFocusSession(id: session.id, now: now); reloadFocus() }
    // The prompt is a sheet, and so is the panel; only one of them can be on
    // screen. Remembering which surface asked lets the panel come back.
    resumesFocusPanel = showsFocusPanel
    showsFocusPanel = false
  }

  /// Drops the prompt and resumes a previously running block, excluding the
  /// time spent answering the quality question.
  func cancelFocusCompletion() {
    if let pending = pendingFocusCompletion, !pending.wasPaused {
      perform { try store?.resumeFocusSession(id: pending.sessionID); reloadFocus() }
    }
    pendingFocusCompletion = nil
    restoreFocusPanelIfItWasOpen()
  }

  /// Credits the time actually spent, so a daily's contribution reflects the
  /// sitting rather than the estimate, and scores it by the multiplier given.
  func confirmFocusCompletion(multiplier: Double) {
    guard let store, let pending = pendingFocusCompletion else { return }
    perform {
      let completion = try store.completeActiveFocusTask(
        sessionId: pending.sessionID, elapsedSeconds: pending.seconds, qualityMultiplier: multiplier,
        completeTask: pending.completeTask, expectedBlockId: pending.blockID, context: effectiveFocusContext)
      pendingFocusCompletion = nil
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
    synchroniseFocusClock(now: .now)
    guard let store, let session = activeFocusSession else { return }
    perform {
      if session.activeTaskId != nil {
        _ = try store.completeActiveFocusTask(sessionId: session.id, elapsedSeconds: session.elapsedSeconds(now: .now),
          completeTask: false, expectedBlockId: session.activeBlockId, context: effectiveFocusContext)
      }
      try store.finishFocusSession(id: session.id)
      reloadFocus()
      reloadNextUp()
      showsFocusPanel = false
    }
  }
}
