import Foundation

/// Everything sitting on one point of the matrix.
///
/// Inheritance means a coordinate is shared exactly, not approximately: place
/// seven goals and two hundred descendants land on seven points, stacked. The
/// plot drew all two hundred, so all but the topmost of each pile were
/// invisible, unhoverable and undraggable — and the two hundred views were the
/// last real cost left on the surface.
public struct MatrixCluster<Task: VisibilityTask> {
  /// The task the cluster answers for: the one that put the pile here, when
  /// there is one, so that dragging the cluster moves the coordinate every
  /// other task in it is inheriting.
  public let representative: Task
  /// Every task at this point, the representative included, in the order the
  /// caller gave them.
  public let taskIds: [Int]
  public let urgency: Double
  public let importance: Double
  /// True when no task here set the coordinate itself — the whole pile is
  /// borrowing it from an ancestor outside the pile.
  public let isInherited: Bool

  public init(
    representative: Task,
    taskIds: [Int],
    urgency: Double,
    importance: Double,
    isInherited: Bool
  ) {
    self.representative = representative
    self.taskIds = taskIds
    self.urgency = urgency
    self.importance = importance
    self.isInherited = isInherited
  }

  public var count: Int { taskIds.count }
}

/// One dot per coordinate rather than one dot per task.
public enum MatrixClustering {

  /// A coordinate, as something a dictionary can key on. Nested types cannot
  /// live inside a generic function, so it sits out here.
  private struct Key: Hashable {
    let urgency: Double
    let importance: Double
  }

  /// Groups placed tasks by the exact coordinate they resolve to.
  ///
  /// Order is by first appearance, so the plot does not reshuffle itself when
  /// an unrelated task changes. Tasks with no level are skipped: they belong to
  /// the unplaced rail, not to a point.
  public static func clusters<Task: VisibilityTask>(
    for tasks: [Task],
    levels: [Int: EffectiveEisenhowerLevel]
  ) -> [MatrixCluster<Task>] {
    // Built in two passes rather than one so that the representative can be a
    // task that appears *after* the first member of its pile. A goal is
    // ordinarily listed before its descendants, but nothing guarantees it, and
    // picking the wrong representative means dragging the cluster moves an
    // inherited task instead of the coordinate everything else follows.
    var order: [Key] = []
    var members: [Key: [Task]] = [:]
    for task in tasks {
      guard let level = levels[task.id] else { continue }
      let key = Key(urgency: level.urgency, importance: level.importance)
      if members[key] == nil {
        members[key] = []
        order.append(key)
      }
      members[key]?.append(task)
    }

    return order.compactMap { key in
      guard let group = members[key], let first = group.first else { return nil }
      let owner = group.first { levels[$0.id]?.isInherited == false }
      return MatrixCluster(
        representative: owner ?? first,
        taskIds: group.map(\.id),
        urgency: key.urgency,
        importance: key.importance,
        isInherited: owner == nil
      )
    }
  }

  /// How wide to draw a cluster's dot.
  ///
  /// Square-rooted so that the *area* tracks the count — thirty tasks read as
  /// bigger than five without a pile of thirty swallowing its quadrant — and
  /// clamped at both ends so a single task keeps the plain 6pt dot and no
  /// cluster grows past a label.
  public static func dotDiameter(count: Int, base: Double = 6, maximum: Double = 18) -> Double {
    guard count > 1 else { return base }
    return min(maximum, base * Double(count).squareRoot())
  }
}
