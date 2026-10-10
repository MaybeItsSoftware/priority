import Foundation

/// Pure functions over Checkvist-shaped tasks: which due bucket a task falls
/// in, and how tasks relate in the outline.
///
/// What is left of the engine that filtered and sorted the legacy task list.
/// That list, and the view model that drew it, went in Phase 6 of the desktop
/// roadmap; these stayed because the daily log's plan buckets by due date
/// (`DayLogPlan`) and the Checkvist sync path still removes and restores
/// whole subtrees.
///
/// Generic over `VisibilityTask` rather than naming `CheckvistTask`, which is
/// what lets it live in `TaktCore` and be tested directly.
public struct TaskFilterEngine {

  // MARK: - Due bucket classification

  public static func classifyDueBucket<Task: VisibilityTask>(
    task: Task, now: Date = Date(), calendar: Calendar = .current
  ) -> RootDueBucket {
    let dueText = task.due?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    guard !dueText.isEmpty else { return .noDueDate }
    if dueText == "asap" { return .asap }
    if dueText == "today" { return .today }
    if dueText == "tomorrow" || dueText == "tmr" { return .tomorrow }
    if dueText == "next week" || dueText == "next 7 days" { return .nextSevenDays }
    guard let dueDate = task.dueDate else { return .future }

    let todayStart = calendar.startOfDay(for: now)
    if dueDate < todayStart { return .overdue }
    if calendar.isDate(dueDate, inSameDayAs: now) { return .today }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart),
      calendar.isDate(dueDate, inSameDayAs: tomorrow)
    {
      return .tomorrow
    }
    guard let sevenDaysOut = calendar.date(byAdding: .day, value: 8, to: todayStart) else {
      return .future
    }
    if dueDate < sevenDaysOut { return .nextSevenDays }
    return .future
  }

  // MARK: - Ancestry

  public static func isDescendant<Task: VisibilityTask>(
    _ task: Task,
    of rootId: Int,
    taskById: [Int: Task]
  ) -> Bool {
    if rootId == 0 { return true }
    var pid = task.parentId ?? 0
    // Cycles should be impossible in server data, but a corrupt list or a
    // half-applied reparent can produce one, and this walk runs on the main
    // actor — an unguarded loop freezes the app rather than merely answering
    // wrongly.
    var seen: Set<Int> = []
    while pid != 0, seen.insert(pid).inserted {
      if pid == rootId { return true }
      pid = taskById[pid]?.parentId ?? 0
    }
    return false
  }

  /// The contiguous span of `flatTasks` covering `taskId` and the run of its
  /// descendants straight after it, or `nil` when the task isn't there.
  ///
  /// Checkvist hands a list back depth-first, so that run is the task's whole
  /// subtree. Ancestry is resolved against the same array.
  public static func subtreeBlockRange<Task: VisibilityTask>(
    for taskId: Int, in flatTasks: [Task]
  ) -> Range<Int>? {
    guard let start = flatTasks.firstIndex(where: { $0.id == taskId }) else { return nil }
    let taskById = Dictionary(
      flatTasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var end = start + 1
    while end < flatTasks.count,
      isDescendant(flatTasks[end], of: taskId, taskById: taskById)
    {
      end += 1
    }
    return start..<end
  }

  // MARK: - The Checkvist cursor

  /// The tasks at the Checkvist cursor's level: the children of `parentId`
  /// (0 for the root), in the order the list holds them.
  ///
  /// No surface draws this any more. It is what the sync and mutation
  /// services still select into after a fetch, an insert or a removal, so it
  /// only has to be stable and in range, not filtered for a view.
  public static func cursorLevel<Task: VisibilityTask>(_ tasks: [Task], parentId: Int) -> [Task] {
    tasks.filter { ($0.parentId ?? 0) == parentId }
  }

  /// The task at `index` in `level`, clamped into range; `nil` when the level
  /// is empty.
  public static func cursorTask<Task: VisibilityTask>(in level: [Task], index: Int) -> Task? {
    guard !level.isEmpty else { return nil }
    return level[min(max(index, 0), level.count - 1)]
  }
}
