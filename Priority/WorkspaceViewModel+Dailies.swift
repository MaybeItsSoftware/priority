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
        .filter { !skippedTaskIDs.contains($0.candidate.id) }
      nextUp = ranked.first
      nextUpAlternatives = Array(ranked.dropFirst().prefix(3))
    }
  }

  func nextUpTask() -> WorkspaceTask? {
    guard let id = nextUp?.candidate.id, let store else { return nil }
    return try? store.task(id: id)
  }

  /// Passes over the current suggestion without rescheduling it. It comes back
  /// next time the app launches, which is the point — a skip is not a decision.
  func skipNextUp() {
    guard let id = nextUp?.candidate.id else { return }
    skippedTaskIDs.insert(id)
    reloadNextUp()
  }

  func clearSkippedTasks() {
    guard !skippedTaskIDs.isEmpty else { return }
    skippedTaskIDs.removeAll()
    reloadNextUp()
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
