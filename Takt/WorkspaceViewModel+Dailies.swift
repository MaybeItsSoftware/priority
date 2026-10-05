import Foundation
import TaktCore
import TaktWorkspace

/// One task in today, and why it is there. `reason` is nil only for the
/// fallback ranking, where nothing chose the task at all.
struct DayItem: Identifiable, Equatable {
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

  /// Marks the dailies stale; see `refresh(_:)`. Reading them is not a
  /// write, so it no longer passes through `perform` and its side effects.
  func reloadDailies() {
    refresh(.dailies)
  }

  func reloadDailiesNow() {
    guard let store else { return }
    do {
      // Habits are placed before they are read, so the day's list and the
      // board agree about which appearances are showing.
      habitDayKey = DailyContribution.dayKey(for: .now)
      if try store.reconcileHabits() { refresh([.board, .nextUp]) }
      let items = try store.dailies()
      let all = try store.allDailies()
      if dailyItems != items { dailyItems = items }
      dailyTaskIDs = Set(all.map(\.taskId))
      habitTaskIDs = Set(all.filter(\.isHabit).map(\.taskId))
      dailyProgressRevision += 1
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func isDailyProgressTask(_ task: WorkspaceTask) -> Bool {
    dailyTaskIDs.contains(task.id)
  }

  func isHabitTask(_ task: WorkspaceTask) -> Bool {
    habitTaskIDs.contains(task.id)
  }

  /// The first check of a new day puts that day's habits in their columns
  /// and takes yesterday's dropped ones out. Driven by the external-write
  /// poll, which already ticks once a second.
  func checkForDayChange() {
    guard habitDayKey != nil, habitDayKey != DailyContribution.dayKey(for: .now) else { return }
    reloadDailies()
    reloadNextUp()
  }

  /// Saves the habit form. Returns an error message, or nil once saved.
  func saveHabit(_ draft: HabitDraft, habitTaskId: String?) -> String? {
    guard let store else { return "The workspace is not open." }
    var failure: String?
    perform {
      do {
        let daily = try store.saveHabit(draft, habitTaskId: habitTaskId)
        selectedTaskID = selectedTaskID ?? daily.taskId
      } catch {
        failure = error.localizedDescription
        throw error
      }
      reloadOutline(refreshSidebar: true)
      reloadDailies()
      reloadNextUp()
    }
    return failure
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

  /// Marks the day and the ladder stale. They are ranked off the main thread
  /// and land a moment later; a caller that reads `focusLadder` on the next
  /// line wants `reloadNextUpNow()` instead. See `WorkspaceViewModel+Refresh`.
  func reloadNextUp() {
    refresh(.nextUp)
  }

  // `dayItems` — today, resolved to tasks, with whatever put each one there —
  // is stored on the class and rebuilt by `rebuildDayItems()`.
  //
  // Every surface that shows the day reads it rather than deriving its own:
  // the panel, Today and the menu bar have to agree about what today is, and
  // three copies of the same fallback is how they stop agreeing.
  //
  // Falling back to the ranked candidates keeps it useful for a workspace that
  // never adopted the Today column and dates nothing — but those are listed as
  // plain tasks, with no reason, because none of them were chosen.

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
}
