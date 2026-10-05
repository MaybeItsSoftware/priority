import Foundation

/// Where a task sits on the matrix, including coordinates it did not set itself.
public struct EffectiveEisenhowerLevel: Equatable, Sendable {
  public let urgency: Double
  public let importance: Double
  /// True when the coordinate came from an ancestor rather than this task.
  public let isInherited: Bool
  /// The ancestor the coordinate came from, when inherited.
  public let sourceTaskId: Int?

  public init(urgency: Double, importance: Double, isInherited: Bool, sourceTaskId: Int?) {
    self.urgency = urgency
    self.importance = importance
    self.isInherited = isInherited
    self.sourceTaskId = sourceTaskId
  }
}

/// A task with no coordinate of its own takes its nearest placed ancestor's.
///
/// This is the whole reason placing tasks is affordable. A tree of a handful of
/// goals and a couple of hundred descendants would otherwise need a couple of
/// hundred placements; with inheritance it needs as many as there are goals,
/// and every descendant is classified the moment its goal is. Refining an
/// individual task then means overriding, not starting from nothing.
///
/// Inheritance is *display and membership only*. Nothing is written to the
/// store on a task's behalf — an inherited coordinate disappears the moment its
/// ancestor's changes, which is the point. Storing it would mean two hundred
/// rows that all have to be corrected by hand later.
public enum EisenhowerInheritance {

  /// The nearest ancestor-or-self with a coordinate of its own.
  ///
  /// Cycle-guarded: this runs during rendering on the main actor, and a corrupt
  /// cache or a half-applied reparent can produce a loop that would freeze the
  /// app rather than merely draw the wrong dot.
  public static func effectiveLevel<Task: VisibilityTask>(
    for task: Task,
    taskById: [Int: Task],
    ownLevel: (Int) -> (urgency: Double, importance: Double)?
  ) -> EffectiveEisenhowerLevel? {
    if let own = ownLevel(task.id),
      MatrixGeometry.isPlaced(urgency: own.urgency, importance: own.importance)
    {
      return EffectiveEisenhowerLevel(
        urgency: own.urgency, importance: own.importance,
        isInherited: false, sourceTaskId: task.id)
    }

    var currentId = task.parentId ?? 0
    var seen: Set<Int> = [task.id]
    while currentId != 0, seen.insert(currentId).inserted {
      if let inherited = ownLevel(currentId),
        MatrixGeometry.isPlaced(urgency: inherited.urgency, importance: inherited.importance)
      {
        return EffectiveEisenhowerLevel(
          urgency: inherited.urgency, importance: inherited.importance,
          isInherited: true, sourceTaskId: currentId)
      }
      currentId = taskById[currentId]?.parentId ?? 0
    }
    return nil
  }

  /// Resolved for a whole list in one pass, which is what a view or a board
  /// membership query wants — calling the single-task form per task walks the
  /// same ancestor chains repeatedly.
  public static func effectiveLevels<Task: VisibilityTask>(
    for tasks: [Task],
    taskById: [Int: Task],
    ownLevel: (Int) -> (urgency: Double, importance: Double)?
  ) -> [Int: EffectiveEisenhowerLevel] {
    var resolved: [Int: EffectiveEisenhowerLevel] = [:]
    for task in tasks {
      if let level = effectiveLevel(for: task, taskById: taskById, ownLevel: ownLevel) {
        resolved[task.id] = level
      }
    }
    return resolved
  }
}
