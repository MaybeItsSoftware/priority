import Foundation

/// The daily log's plan for a day: which tasks it counts as on that day's
/// plate when it takes its once-a-day snapshot.
///
/// This is about Checkvist tasks, and deliberately so. The log keys every
/// event by a Checkvist task's integer id — the plan, and the completions,
/// reopens and deferrals the plan is settled against — and those events are
/// only ever recorded by the Checkvist sync path. A workspace task has a
/// string id the log cannot hold, and nothing records its completion in the
/// log, so a plan of workspace tasks would read as wholly unfinished every
/// day. The workspace's own day is `DayPlanSelector`, which the Today pane
/// draws and which this does not try to mirror.
public enum DayLogPlan {
  /// Open tasks due today or already overdue (an "asap" due counts as
  /// today's), plus anything whose start date has arrived.
  ///
  /// Overdue tasks are included deliberately. They are on today's plate
  /// whether or not today is when they were meant to be done, and a
  /// "planned" figure that ignored them would flatter the day.
  ///
  /// - Parameters:
  ///   - openTasks: the open tasks, in the order the ids should come back.
  ///   - startDate: the task's start date, if one has been set.
  public static func plannedTaskIds<Task: VisibilityTask>(
    openTasks: [Task],
    startDate: (Task) -> Date?,
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> [Int] {
    let todayStart = calendar.startOfDay(for: now)
    return openTasks.filter { task in
      switch TaskFilterEngine.classifyDueBucket(task: task, now: now, calendar: calendar) {
      case .overdue, .asap, .today:
        return true
      case .tomorrow, .nextSevenDays, .future, .noDueDate:
        guard let start = startDate(task) else { return false }
        return calendar.isDate(start, inSameDayAs: now) || start < todayStart
      }
    }
    .map(\.id)
  }
}
