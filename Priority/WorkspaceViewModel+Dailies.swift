import Foundation
import PriorityCore
import PriorityWorkspace

/// One task in today, and why it is there. `reason` is nil only for the
/// fallback ranking, where nothing chose the task at all.
struct DayItem: Identifiable {
  let task: WorkspaceTask
  let reason: DayPlanReason?

  var id: String { task.id }
}

/// Dailies and the next-up ranking. Split from `WorkspaceViewModel.swift` only
/// for size; the state these read lives on the class itself, because stored
/// properties cannot be declared in an extension.
@MainActor
extension WorkspaceViewModel {
  // MARK: - Dailies

  func reloadDailies() {
    guard let store else { return }
    perform {
      dailyItems = try store.dailies()
      dailyTaskIDs = Set(try store.allDailies().map(\.taskId))
      dailyProgressRevision += 1
    }
  }

  func isDailyProgressTask(_ task: WorkspaceTask) -> Bool {
    dailyTaskIDs.contains(task.id)
  }

  /// Attaching a daily to a task is what "make daily progress" now means: the
  /// task keeps its place in its list, and gains a commitment to advance it.
  func setDailyProgressTask(_ task: WorkspaceTask, enabled: Bool) {
    guard let store else { return }
    perform {
      if enabled {
        try store.makeDaily(taskId: task.id, targetSeconds: task.estimateSeconds)
      } else {
        try store.archiveDaily(taskId: task.id)
      }
      reloadDailies()
      reloadNextUp()
    }
  }

  var dailyProgressTasks: [WorkspaceTask] { dailyItems.map(\.task) }

  func dailyItem(for task: WorkspaceTask) -> DailyItem? {
    dailyItems.first { $0.task.id == task.id }
  }

  func isDailyProgressComplete(_ task: WorkspaceTask, on day: Date = .now) -> Bool {
    dailyItem(for: task)?.isDoneToday ?? false
  }

  /// Ticks or un-ticks today. Never touches the task's own status — that is the
  /// distinction the whole model rests on.
  func toggleDailyProgress(_ task: WorkspaceTask, on day: Date = .now) {
    guard let store, let item = dailyItem(for: task) else { return }
    perform {
      if item.isDoneToday {
        try store.clearContribution(dailyId: item.daily.id, on: day)
      } else {
        try store.logContribution(dailyId: item.daily.id, now: day)
        celebrateCompletion(of: task)
      }
      reloadDailies()
      reloadNextUp()
    }
  }

  // MARK: - Next up

  func reloadNextUp() {
    guard let store else { return }
    perform {
      taskLoggedSeconds = try store.loggedWorkTotals()
      taskPlanningByID = try store.taskPlanningValues()
      let selectedID = focusLadderTaskID
      if let workspace { focusConditions = try store.conditions(in: workspace.id) }
      let now = Date.now
      let candidates = try store.nextUpCandidates(now: now)
      // The day is gathered from every candidate rather than from the ranked
      // ones: a task due today that a condition currently rules out is still
      // part of today, and leaving it out would be the panel quietly deciding
      // the day was shorter than it is.
      todayPlan = DayPlanSelector.plan(
        candidates: candidates, runningID: activeFocusSession?.activeTaskId, now: now)
      workProgress = try store.workProgress(now: now)
      let ranking = NextUpSelector.evaluate(candidates, now: now, context: effectiveFocusContext)
      let ranked = ranking.ranked
      focusLadder = ranked
      blockedFocusTasks = ranking.blocked
      nextFocusEvaluationAt = ranking.nextEvaluationAt
      if let id = selectedID, let index = ranked.firstIndex(where: { $0.candidate.id == id }) {
        focusLadderIndex = index
      } else {
        focusLadderIndex = min(focusLadderIndex, max(0, ranked.count - 1))
      }
      if let stagedTaskID, !ranked.contains(where: { $0.id == stagedTaskID }) { self.stagedTaskID = nil }
      nextUp = ranked.first
      if allowsQueueResume && activeFocusSession != nil && activeFocusSession?.activeTaskId == nil {
        try store.resumeEligibleFocusQueue(context: effectiveFocusContext, now: now)
        reloadFocus()
      }
    }
  }

  /// Today, resolved to tasks, with whatever put each one there.
  ///
  /// Every surface that shows the day reads this rather than deriving its own:
  /// the panel, the focus screen and the menu bar have to agree about what
  /// today is, and three copies of the same fallback is how they stop agreeing.
  ///
  /// Falling back to the ranked candidates keeps it useful for a workspace that
  /// never adopted the Today column and dates nothing — but those are listed as
  /// plain tasks, with no reason, because none of them were chosen.
  var dayItems: [DayItem] {
    let planned = todayPlan.compactMap { entry -> DayItem? in
      guard let task = task(withID: entry.id) else { return nil }
      return DayItem(task: task, reason: entry.reason)
    }
    if !planned.isEmpty { return planned }
    return focusLadder.prefix(8)
      .compactMap { task(withID: $0.candidate.id) }
      .map { DayItem(task: $0, reason: nil) }
  }

  // MARK: - The focus ladder

  /// The rung currently under the cursor. Rung 0 is the most important thing;
  /// climbing raises the index and lowers the priority.
  var focusLadderSelection: ScoredNextUp? {
    guard focusLadder.indices.contains(focusLadderIndex) else { return nil }
    return focusLadder[focusLadderIndex]
  }

  var focusLadderTask: WorkspaceTask? {
    guard let id = focusLadderSelection?.candidate.id else { return nil }
    return task(withID: id)
  }

  private var focusLadderTaskID: String? { focusLadderSelection?.candidate.id }

  /// `offset` of +1 climbs to the next less important task, -1 descends back
  /// towards the most important one. Deliberately clamped rather than wrapped:
  /// the ladder has a top and a bottom, and wrapping would hide which you are at.
  func moveFocusLadder(by offset: Int) {
    guard !focusLadder.isEmpty else { return }
    let target = focusLadderIndex + offset
    guard focusLadder.indices.contains(target) else { return }
    focusLadderIndex = target
    stagedTaskID = nil
  }

  /// Commits to the rung under the cursor: it becomes the thing you are about
  /// to do, and the estimate is seeded from whatever it already knows.
  func stageFocusLadderSelection() {
    guard let task = focusLadderTask else { return }
    stagedTaskID = task.id
    let candidate = focusLadderSelection?.candidate
    let seconds = candidate.map { TaskAvailabilityPolicy.suggestedSeconds(for: $0, context: effectiveFocusContext, now: .now) } ?? 1500
    focusEstimateMinutes = max(1, Double(seconds) / 60)
  }

  func unstageFocusTask() {
    stagedTaskID = nil
  }

  var stagedTask: WorkspaceTask? {
    guard let id = stagedTaskID else { return nil }
    return task(withID: id)
  }

  /// Begins work on the staged task with the committed estimate.
  func beginStagedFocus() {
    guard let task = stagedTask else { return }
    let seconds = (max(1, focusEstimateMinutes) * 60).rounded()
    guard seconds.isFinite, seconds < Double(Int.max) else { errorMessage = "Choose a supported session duration."; return }
    startFocus(on: task, plannedSeconds: Int(seconds), automatic: true)
  }

  /// Describes what ticking the current rung off would be an instance of, so
  /// the celebration can be chosen before the row is gone.
  ///
  /// Built here rather than in the view because every input is a question about
  /// stored state — which rung, whether it is a daily, how the day has gone —
  /// and the view has none of that.
  func focusCompletionEvent() -> CompletionEvent? {
    guard let task = focusLadderTask else { return nil }
    // The rung being ticked is still in the ladder, so one left means this is
    // the last of them.
    return completionEvent(for: task, remainingVisibleTaskCount: focusLadder.count)
  }

  /// What finishing this task is worth as an occasion: which kind of thing it
  /// is, and whether it lands on a milestone.
  ///
  /// Every surface that can finish something builds one of these, so that the
  /// reward for a day's last task does not depend on which screen you happened
  /// to finish it from.
  func completionEvent(for task: WorkspaceTask, remainingVisibleTaskCount: Int) -> CompletionEvent? {
    guard let store else { return nil }
    let item = dailyItem(for: task)
    let kind: CompletionKind = item.map { .daily(id: $0.daily.id) } ?? .workspaceTask(id: task.id)
    let context = (try? store.completionContext()) ?? .init(ordinalToday: 1, streakDays: 0)
    let milestone = CompletionMilestonePolicy.milestone(
      for: kind,
      remainingVisibleTaskCount: remainingVisibleTaskCount,
      ordinal: context.ordinalToday,
      streakDays: context.streakDays)
    return CompletionEvent(kind: kind, milestone: milestone, ordinal: context.ordinalToday)
  }

  /// Ticks the rung under the cursor off without ever starting a session —
  /// the "actually, that's already done" path that stops the ladder being a
  /// list you can only work through one sitting at a time.
  func completeFocusLadderSelection() {
    guard let store, let task = focusLadderTask else { return }
    perform {
      if let item = dailyItem(for: task), !item.isDoneToday {
        try store.logContribution(dailyId: item.daily.id)
      } else {
        try store.setStatus(.completed, for: task.id)
      }
      stagedTaskID = nil
      reloadDailies()
      reloadOutline()
      reloadNextUp()
    }
  }

  /// Moves the task under the cursor through the ladder by hand, and follows it
  /// with the cursor so the same task stays selected.
  ///
  /// Writing the whole visible order rather than one rank keeps the arrangement
  /// stable: a single pinned task among floating ones drifts as soon as a due
  /// date passes.
  func reorderFocusLadder(by offset: Int) {
    guard let store, !focusLadder.isEmpty else { return }
    let target = focusLadderIndex + offset
    guard focusLadder.indices.contains(target) else { return }
    let moved = focusLadder[focusLadderIndex].candidate.id
    perform {
      // Only the task that moved is pinned. Its neighbour is left to the
      // ranking, so a nudge stays a nudge instead of freezing the ladder.
      try store.pinTask(id: moved, atIndex: target)
      focusLadderIndex = target
      stagedTaskID = nil
      reloadNextUp()
    }
  }

  /// Gives the ladder back to the ranking.
  func clearManualFocusOrder() {
    guard let store else { return }
    perform {
      try store.clearFocusOrder()
      reloadNextUp()
    }
  }

  var hasManualFocusOrder: Bool {
    (try? store?.hasManualFocusOrder()) == true
  }

  /// Defers the task under the cursor. The default is tomorrow morning, which
  /// is what "not today" almost always means.
  func deferFocusLadderSelection(_ deferral: WorkspaceDeferral = .tomorrow) {
    guard let task = focusLadderTask else { return }
    scheduleForLater(task, until: deferral.date(from: .now))
  }

  /// Leaves the focus screen, putting the ladder back at the top for next time.
  ///
  /// Called by every sidebar selection as well as by Escape: focus is a screen
  /// you are looking at, not a mode you are trapped in, so asking to see a list
  /// is a complete answer to "what now" and should simply show you the list.
  func dismissFocusScreen() {
    showsFocusScreen = false
    stagedTaskID = nil
    focusLadderIndex = 0
  }

  /// Pushes the suggestion out to `date`, so it stops being offered until then.
  func scheduleForLater(_ task: WorkspaceTask, until date: Date) {
    guard let store else { return }
    perform {
      try store.scheduleTask(id: task.id, startAt: date)
      reloadNextUp()
      reloadDailies()
      reloadOutline()
    }
  }
}
