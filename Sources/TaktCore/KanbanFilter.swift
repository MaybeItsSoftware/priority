import Foundation

/// Which column a task belongs to, and in what order tasks sit within one.
///
/// Lifted out of `KanbanManager`, where every one of these read its inputs
/// through a `weak dataSource` back to the coordinator. That made them
/// impossible to reach from a test — so the rules deciding which column a
/// task lands in, and the five-way tie-break that orders it, had no coverage at
/// all in a view whose whole purpose is that placement.
///
/// Everything here takes its inputs as parameters. Generic over
/// `VisibilityTask` for the same reason `TaskVisibilityEngine` is: sorting a
/// board has nothing to do with Checkvist.
public enum KanbanFilter {

  // MARK: - Membership

  /// Every descendant of `rootId`, excluding the root itself.
  public static func subtreeTasks<Task: VisibilityTask>(
    in tasks: [Task],
    rootId: Int,
    taskById: [Int: Task]
  ) -> [Task] {
    tasks.filter { task in
      task.id != rootId && TaskFilterEngine.isDescendant(task, of: rootId, taskById: taskById)
    }
  }

  /// Everything membership needs to know about a task beyond the task itself.
  ///
  /// Gathered into one value because the condition vocabulary grew past what
  /// two parameters could carry. A column can now be defined by quadrant,
  /// priority, leafness or matrix-absence as well as tag and due bucket, and
  /// threading six arguments through three functions is how they drift apart.
  public struct MembershipInputs<Task: VisibilityTask> {
    public let tagsByTaskId: [Int: [String]]
    public let dueBucket: (Task) -> RootDueBucket
    /// `nil` for a task with no coordinate. `(0, 0)` is the unset sentinel and
    /// is treated the same way, since the store discards it on save.
    public let eisenhowerByTaskId: [Int: (urgency: Double, importance: Double)]
    /// The better of the absolute and scoped ranks, already resolved.
    public let priorityRankByTaskId: [Int: Int]
    public let childCountByTaskId: [Int: Int]

    public init(
      tagsByTaskId: [Int: [String]] = [:],
      dueBucket: @escaping (Task) -> RootDueBucket,
      eisenhowerByTaskId: [Int: (urgency: Double, importance: Double)] = [:],
      priorityRankByTaskId: [Int: Int] = [:],
      childCountByTaskId: [Int: Int] = [:]
    ) {
      self.tagsByTaskId = tagsByTaskId
      self.dueBucket = dueBucket
      self.eisenhowerByTaskId = eisenhowerByTaskId
      self.priorityRankByTaskId = priorityRankByTaskId
      self.childCountByTaskId = childCountByTaskId
    }
  }

  /// Whether a task satisfies one column condition.
  ///
  /// `.catchAll` deliberately answers `false`. A column configured with only a
  /// catch-all therefore collects nothing here — placement is driven by
  /// specific conditions, and the catch-all is applied by the caller as the
  /// column that takes what no earlier column claimed.
  public static func matches<Task: VisibilityTask>(
    _ task: Task,
    condition: KanbanColumnCondition,
    inputs: MembershipInputs<Task>
  ) -> Bool {
    switch condition {
    case .tag(let name):
      return hasTag(task, tag: name, tagsByTaskId: inputs.tagsByTaskId)
    case .dueBucket(let raw):
      guard let bucket = RootDueBucket(rawValue: raw) else { return false }
      return inputs.dueBucket(task) == bucket
    case .catchAll:
      return false
    case .matrixQuadrant(let raw):
      guard let wanted = MatrixQuadrant(rawValue: raw),
        let point = inputs.eisenhowerByTaskId[task.id],
        MatrixGeometry.isPlaced(urgency: point.urgency, importance: point.importance)
      else { return false }
      return MatrixGeometry.quadrant(urgency: point.urgency, importance: point.importance)
        == wanted
    case .priorityAtLeast(let rank):
      guard let actual = inputs.priorityRankByTaskId[task.id] else { return false }
      // Rank 1 is the top, so "at least P3" is a rank *no greater than* 3.
      return actual <= rank
    case .leafOnly:
      return (inputs.childCountByTaskId[task.id] ?? 0) == 0
    case .unplacedOnMatrix:
      guard let point = inputs.eisenhowerByTaskId[task.id] else { return true }
      return !MatrixGeometry.isPlaced(urgency: point.urgency, importance: point.importance)
    }
  }

  /// A column matches when *any* of its conditions do.
  public static func matchesColumn<Task: VisibilityTask>(
    _ task: Task,
    column: KanbanColumn,
    includeCatchAll: Bool = true,
    inputs: MembershipInputs<Task>
  ) -> Bool {
    for condition in column.conditions {
      if !includeCatchAll, condition == .catchAll { continue }
      if matches(task, condition: condition, inputs: inputs) {
        return true
      }
    }
    return false
  }

  /// The first column, in order, that claims this task.
  public static func column<Task: VisibilityTask>(
    for task: Task,
    in columns: [KanbanColumn],
    inputs: MembershipInputs<Task>
  ) -> KanbanColumn? {
    columns.first { column in
      matchesColumn(task, column: column, inputs: inputs)
    }
  }

  /// Tags are stored with their sigil. A bare condition name means a hashtag,
  /// so `waiting` matches `#waiting` but an explicit `@waiting` matches only
  /// the mention form.
  public static func hasTag<Task: VisibilityTask>(
    _ task: Task,
    tag: String,
    tagsByTaskId: [Int: [String]]
  ) -> Bool {
    guard let tags = tagsByTaskId[task.id] else { return false }
    let normalized =
      tag.hasPrefix("#") || tag.hasPrefix("@")
      ? tag.lowercased()
      : "#\(tag.lowercased())"
    return tags.contains(normalized)
  }

  // MARK: - Ordering

  /// The ranks and tags an ordering needs, gathered once rather than fetched
  /// per comparison — a sort asks for these O(n log n) times.
  public struct SortInputs {
    public let absolutePriorityRank: [Int: Int]
    public let priorityRank: [Int: Int]
    public let tagsByTaskId: [Int: [String]]

    public init(
      absolutePriorityRank: [Int: Int] = [:],
      priorityRank: [Int: Int] = [:],
      tagsByTaskId: [Int: [String]] = [:]
    ) {
      self.absolutePriorityRank = absolutePriorityRank
      self.priorityRank = priorityRank
      self.tagsByTaskId = tagsByTaskId
    }
  }

  public static func sorted<Task: VisibilityTask>(
    _ tasks: [Task],
    sortOrder: KanbanSortOrder,
    inputs: SortInputs
  ) -> [Task] {
    switch sortOrder {
    case .position:
      return tasks.sorted(by: comparePositionThenContent)
    case .dueAscending:
      return sortByDue(tasks, ascending: true)
    case .dueDescending:
      return sortByDue(tasks, ascending: false)
    case .priorityAscending:
      return tasks.sorted { comparePriority($0, $1, inputs: inputs) ?? comparePositionThenContent($0, $1) }
    case .priorityThenDueAscending:
      return tasks.sorted { lhs, rhs in
        if let byPriority = comparePriority(lhs, rhs, inputs: inputs) { return byPriority }
        if let byDue = compareDue(lhs, rhs, ascending: true) { return byDue }
        // A tagged task ahead of an untagged one: with everything else equal,
        // the one carrying context is the more actionable.
        let leftTagged = inputs.tagsByTaskId[lhs.id] != nil
        let rightTagged = inputs.tagsByTaskId[rhs.id] != nil
        if leftTagged != rightTagged { return leftTagged }
        return comparePositionThenContent(lhs, rhs)
      }
    case .alphabetical:
      return tasks.sorted { lhs, rhs in
        let comparison = lhs.content.localizedCaseInsensitiveCompare(rhs.content)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return comparePositionThenContent(lhs, rhs)
      }
    }
  }

  /// `nil` when the two rank equally and the caller should fall through to its
  /// next tie-break. Absolute priority outranks scoped priority, and any rank
  /// outranks none.
  private static func comparePriority<Task: VisibilityTask>(
    _ lhs: Task, _ rhs: Task, inputs: SortInputs
  ) -> Bool? {
    let leftAbsolute = inputs.absolutePriorityRank[lhs.id]
    let rightAbsolute = inputs.absolutePriorityRank[rhs.id]
    if let leftAbsolute, let rightAbsolute, leftAbsolute != rightAbsolute {
      return leftAbsolute < rightAbsolute
    }
    if leftAbsolute != nil, rightAbsolute == nil { return true }
    if leftAbsolute == nil, rightAbsolute != nil { return false }

    let leftScoped = inputs.priorityRank[lhs.id]
    let rightScoped = inputs.priorityRank[rhs.id]
    if let leftScoped, let rightScoped, leftScoped != rightScoped {
      return leftScoped < rightScoped
    }
    if leftScoped != nil, rightScoped == nil { return true }
    if leftScoped == nil, rightScoped != nil { return false }
    return nil
  }

  /// `nil` when both are undated or share a date. A dated task always precedes
  /// an undated one, in both directions — "latest first" orders the dates, it
  /// does not promote the undated.
  private static func compareDue<Task: VisibilityTask>(
    _ lhs: Task, _ rhs: Task, ascending: Bool
  ) -> Bool? {
    switch (lhs.dueDate, rhs.dueDate) {
    case (.some(let left), .some(let right)) where left != right:
      return ascending ? left < right : left > right
    case (.some, .none):
      return true
    case (.none, .some):
      return false
    default:
      return nil
    }
  }

  private static func sortByDue<Task: VisibilityTask>(
    _ tasks: [Task], ascending: Bool
  ) -> [Task] {
    tasks.sorted { lhs, rhs in
      compareDue(lhs, rhs, ascending: ascending) ?? comparePositionThenContent(lhs, rhs)
    }
  }

  /// Board order differs from the list's `TaskFilterEngine` comparator in one
  /// respect: a task with no position sorts *after* one that has a position,
  /// rather than being treated as equal to it.
  public static func comparePositionThenContent<Task: VisibilityTask>(
    _ lhs: Task, _ rhs: Task
  ) -> Bool {
    switch (lhs.position, rhs.position) {
    case (.some(let left), .some(let right)) where left != right:
      return left < right
    case (.some, .none):
      return true
    case (.none, .some):
      return false
    default:
      return lhs.content.localizedCaseInsensitiveCompare(rhs.content) == .orderedAscending
    }
  }
}
