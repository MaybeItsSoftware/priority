import Foundation
import PriorityCore
import PriorityWorkspace

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
      }
      reloadDailies()
      reloadNextUp()
    }
  }

  // MARK: - Next up

  func reloadNextUp() {
    guard let store else { return }
    perform {
      let ranked = NextUpSelector.rank(try store.nextUpCandidates())
      focusLadder = ranked
      // Keep the cursor pointing at the same task across a reload where we can;
      // ticking one off should not throw away where you had climbed to.
      if let id = focusLadderTaskID, let index = ranked.firstIndex(where: { $0.candidate.id == id }) {
        focusLadderIndex = index
      } else {
        focusLadderIndex = min(focusLadderIndex, max(0, ranked.count - 1))
      }
      nextUp = ranked.first
    }
  }

  // MARK: - The focus ladder

  /// The rung currently under the cursor. Rung 0 is the most important thing;
  /// climbing raises the index and lowers the priority.
  var focusLadderSelection: ScoredNextUp? {
    guard focusLadder.indices.contains(focusLadderIndex) else { return nil }
    return focusLadder[focusLadderIndex]
  }

  var focusLadderTask: WorkspaceTask? {
    guard let id = focusLadderSelection?.candidate.id, let store else { return nil }
    return try? store.task(id: id)
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
    let seconds = dailyItem(for: task)?.daily.targetSeconds ?? task.estimateSeconds
    focusEstimateMinutes = seconds.map { max(1, $0 / 60) } ?? 25
  }

  func unstageFocusTask() {
    stagedTaskID = nil
  }

  var stagedTask: WorkspaceTask? {
    guard let id = stagedTaskID, let store else { return nil }
    return try? store.task(id: id)
  }

  /// Begins work on the staged task with the committed estimate.
  func beginStagedFocus() {
    guard let task = stagedTask else { return }
    stagedTaskID = nil
    startFocus(on: task, plannedSeconds: max(1, focusEstimateMinutes) * 60)
  }

  /// Describes what ticking the current rung off would be an instance of, so
  /// the celebration can be chosen before the row is gone.
  ///
  /// Built here rather than in the view because every input is a question about
  /// stored state — which rung, whether it is a daily, how the day has gone —
  /// and the view has none of that.
  func focusCompletionEvent() -> CompletionEvent? {
    guard let store, let task = focusLadderTask else { return nil }
    let item = dailyItem(for: task)
    let kind: CompletionKind = item.map { .daily(id: $0.daily.id) } ?? .workspaceTask(id: task.id)
    let context = (try? store.completionContext()) ?? .init(ordinalToday: 1, streakDays: 0)
    let milestone = CompletionMilestonePolicy.milestone(
      for: kind,
      // The rung being ticked is still in the ladder, so one left means this is
      // the last of them.
      remainingVisibleTaskCount: focusLadder.count,
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
    var order = focusLadder.map(\.candidate.id)
    order.swapAt(focusLadderIndex, target)
    perform {
      try store.setFocusOrder(order)
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

  /// Leaves focus mode, putting the ladder back at the top for next time.
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
