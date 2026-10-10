import Foundation

/// Pure, stateless filter and sort functions for task visibility computation.
/// Extracted from `AppCoordinator+TaskScoping` so the algorithms can be
/// reasoned about and tested without coordinator state.
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

  public static func computeRootDueBuckets<Task: VisibilityTask>(tasks: [Task]) -> [Int: RootDueBucket] {
    Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, classifyDueBucket(task: $0)) })
  }

  // MARK: - Tag extraction

  public static let tagRegex: NSRegularExpression = {
    guard let regex = try? NSRegularExpression(pattern: "[@#][a-zA-Z0-9_\\-]+") else {
      fatalError("Failed to build task tag regex.")
    }
    return regex
  }()

  public static func extractTagsByTaskId<Task: VisibilityTask>(tasks: [Task]) -> [Int: [String]] {
    var result: [Int: [String]] = [:]
    for task in tasks {
      let range = NSRange(task.content.startIndex..., in: task.content)
      let matches = tagRegex.matches(in: task.content, range: range)
      guard !matches.isEmpty else { continue }
      result[task.id] = matches.compactMap { match in
        Range(match.range, in: task.content).map { String(task.content[$0]).lowercased() }
      }
    }
    return result
  }

  // MARK: - Ancestry

  public static func isDescendant<Task: VisibilityTask>(
    _ task: Task,
    of rootId: Int,
    taskById: [Int: Task]
  ) -> Bool {
    if rootId == 0 { return true }
    var pid = task.parentId ?? 0
    // Cycles should be impossible in server data, but a corrupt cache or a
    // half-applied reparent can produce one, and this walk runs on the main
    // actor during every cache rebuild — an unguarded loop freezes the app
    // rather than merely showing the wrong rows.
    var seen: Set<Int> = []
    while pid != 0, seen.insert(pid).inserted {
      if pid == rootId { return true }
      pid = taskById[pid]?.parentId ?? 0
    }
    return false
  }

  // MARK: - Comparators

  public static func compareByPositionThenContent<Task: VisibilityTask>(_ lhs: Task, _ rhs: Task) -> Bool
  {
    switch (lhs.position, rhs.position) {
    case (.some(let leftPosition), .some(let rightPosition)) where leftPosition != rightPosition:
      return leftPosition < rightPosition
    default:
      break
    }
    return lhs.content.localizedCaseInsensitiveCompare(rhs.content) == .orderedAscending
  }

  public static func compareByPriorityThenPosition<Task: VisibilityTask>(
    _ lhs: Task,
    _ rhs: Task,
    priorityRankById: [Int: Int],
    absolutePriorityRankById: [Int: Int]
  ) -> Bool {
    let leftAbsolute = absolutePriorityRankById[lhs.id]
    let rightAbsolute = absolutePriorityRankById[rhs.id]

    if let leftAbsolute, let rightAbsolute, leftAbsolute != rightAbsolute {
      return leftAbsolute < rightAbsolute
    }
    if leftAbsolute != nil && rightAbsolute == nil { return true }
    if leftAbsolute == nil && rightAbsolute != nil { return false }

    let leftPriority = priorityRankById[lhs.id]
    let rightPriority = priorityRankById[rhs.id]

    if let leftPriority, let rightPriority, leftPriority != rightPriority {
      return leftPriority < rightPriority
    }
    if leftPriority != nil && rightPriority == nil { return true }
    if leftPriority == nil && rightPriority != nil { return false }

    return compareByPositionThenContent(lhs, rhs)
  }

  public static func compareByRootDueBucket<Task: VisibilityTask>(
    _ lhs: Task,
    _ rhs: Task,
    rootDueBucketById: [Int: RootDueBucket]
  ) -> Bool {
    let leftBucket = rootDueBucketById[lhs.id] ?? classifyDueBucket(task: lhs)
    let rightBucket = rootDueBucketById[rhs.id] ?? classifyDueBucket(task: rhs)
    if leftBucket != rightBucket {
      return leftBucket.rawValue < rightBucket.rawValue
    }

    switch (lhs.dueDate, rhs.dueDate) {
    case (.some(let leftDate), .some(let rightDate)) where leftDate != rightDate:
      return leftDate < rightDate
    default:
      break
    }

    return compareByPositionThenContent(lhs, rhs)
  }
}
