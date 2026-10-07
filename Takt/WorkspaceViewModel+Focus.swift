import Foundation
import TaktWorkspace
import TaktCore

/// Where the "how did that go?" question is asked.
enum FocusCompletionSurface {
  case window
  case panel
}

/// Starting, advancing and ending a focus session. Split from
/// `WorkspaceViewModel.swift` only for size.
@MainActor
extension WorkspaceViewModel {
  /// `plannedSeconds` is the estimate committed to, if any. Without one the
  /// task's own estimate is used, and failing that a default block.
  func startFocus(on task: WorkspaceTask, plannedSeconds: Int? = nil, override: Bool = false) {
    guard !task.isList else { openItemList(task); return }
    guard let store else { return }
    perform {
      let now = Date.now
      let candidate = try store.nextUpCandidates(now: now).first { $0.id == task.id }
      let reasons = candidate.map { TaskAvailabilityPolicy.reasons(for: $0, context: effectiveFocusContext, now: now) }
      let planned = plannedSeconds ?? candidate.map { TaskAvailabilityPolicy.suggestedSeconds(for: $0, context: effectiveFocusContext, now: now) } ?? 1500
      var explanations = reasons?.map { unavailableDescription($0) } ?? ["This task is not currently available for automatic focus."]
      if let end = effectiveFocusContext.endsAt, Double(planned) > end.timeIntervalSince(now) {
        explanations.append("The planned block exceeds your available time.")
      }
      if let candidate, planned < max(60, candidate.minimumBlockSeconds ?? 60) ||
        (candidate.requiresSingleSitting && planned < (candidate.remainingSeconds ?? Int.max)) {
        explanations.append("The block is shorter than this task needs.")
      }
      if !override && !explanations.isEmpty {
        focusStartOverride = FocusStartOverride(task: task, plannedSeconds: planned, explanation: explanations.joined(separator: "\n"))
        return
      }
      allowsQueueResume = true
      activeFocusSession = try store.startFocusSession(
        taskId: task.id, plannedSeconds: planned, context: effectiveFocusContext, overrideAvailability: override)
      reloadFocus()
      reloadNextUp()
      // Where the block runs is the panel or the menu bar, never a pane of
      // the window: a deliberate start hands over to it and closes the window.
      focusHandoffRequest += 1
    }
  }

  /// Focus has one surface, the floating panel: the day to pick from while
  /// nothing runs, the block's strip once something does. It used to have a
  /// pane in the window as well, which took the keyboard over without saying
  /// so; now ⌘8, the toolbar and Today's button all just raise the panel.
  func openFocusPanel() {
    focusFloatRequest += 1
  }

  /// Opens the timeline in the right dock, beside whatever you are working
  /// on, with the keyboard on it. It used to take the whole main pane, which
  /// meant leaving the list to look at the day.
  func presentTimelineScreen() {
    showRightDock(.timeline)
    requestKeyboardFocus(.timeline)
  }

  func dismissTimelineScreen() {
    guard showsTimelineScreen else { return }
    hideRightDock()
  }

  /// There is no full-pane screen any more: the timeline sits in the dock
  /// beside the work, so navigating leaves it where it is. Nothing left to
  /// do here; the remaining callers in the views can drop it.
  func leaveFullPaneScreens() {}

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
    if activeFocusSession != nil { openFocusPanel(); return }
    // Read on the next line, so it cannot wait for the background ranking.
    reloadNextUpNow()
    let available = Set(focusLadder.map(\.id))
    let planned = todayTasks.filter { available.contains($0.id) }
    guard let first = planned.first else { errorMessage = "No Today task is available in this context and time window."; return }
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
      focusHandoffRequest += 1
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
  func requestFocusCompletion(
    now: Date = .now, completeTask: Bool = true, from surface: FocusCompletionSurface = .window
  ) {
    synchroniseFocusClock(now: now)
    guard pendingFocusCompletion == nil, let session = activeFocusSession, let task = activeFocusTask else { return }
    focusCompletionSurface = surface
    pendingFocusCompletion = PendingFocusCompletion(
      sessionID: session.id, taskID: task.id, title: task.title,
      seconds: session.elapsedSeconds(now: now), completeTask: completeTask,
      blockID: session.activeBlockId, wasPaused: session.pausedAt != nil)
    perform(mirrors: false) { try store?.pauseFocusSession(id: session.id, now: now); reloadFocus() }
    // Someone who has said they only want the minutes gets them: the block
    // closes at the neutral multiplier and nothing is put in the way of the
    // next one.
    if !asksHowEachBlockWent() { confirmFocusCompletion(multiplier: 1) }
  }

  /// Drops the prompt and resumes a previously running block, excluding the
  /// time spent answering the quality question.
  func cancelFocusCompletion() {
    if let pending = pendingFocusCompletion, !pending.wasPaused {
      perform(mirrors: false) { try store?.resumeFocusSession(id: pending.sessionID); reloadFocus() }
    }
    pendingFocusCompletion = nil
  }

  /// Credits the time actually spent, so a daily's contribution reflects the
  /// sitting rather than the estimate, and scores it by the multiplier given.
  func confirmFocusCompletion(multiplier: Double) {
    guard let store, let pending = pendingFocusCompletion else { return }
    perform {
      let completion: WorkspaceStore.FocusCompletion
      do {
        completion = try store.completeActiveFocusTask(
          sessionId: pending.sessionID, elapsedSeconds: pending.seconds, qualityMultiplier: multiplier,
          completeTask: pending.completeTask, expectedBlockId: pending.blockID, context: effectiveFocusContext)
      } catch WorkspaceStoreError.noActiveFocusTask {
        // The block the question was about has gone — advanced or ended by
        // the CLI, or settled as stale — so there is nothing left to score.
        // Left up, the prompt could never be answered.
        pendingFocusCompletion = nil
        reloadFocus()
        onStatusMessage?("That block had already ended.")
        return
      }
      pendingFocusCompletion = nil
      if pending.completeTask, let task = task(withID: pending.taskID) {
        celebrateCompletion(of: task)
      }
      activeFocusSession = completion.session
      lastFocusOutcome = completion.outcome
      lastFocusAward = completion.award
      reloadFocus()
      reloadOutline()
      reloadDailies()
      reloadNextUp()
    }
  }
}
