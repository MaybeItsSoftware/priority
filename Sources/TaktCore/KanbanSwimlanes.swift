import Foundation

/// A row of the board: one top-level goal and everything of its beneath it.
public struct KanbanSwimlane<Task: VisibilityTask>: Identifiable {
  /// The top-level ancestor's task id. `0` is the lane for tasks that have no
  /// ancestor at all — top-level tasks themselves, and anything orphaned by a
  /// half-applied reparent.
  public let id: Int
  public let title: String
  public let tasks: [Task]

  public init(id: Int, title: String, tasks: [Task]) {
    self.id = id
    self.title = title
    self.tasks = tasks
  }
}

/// Grouping the board into rows by goal.
///
/// A single row of columns can say *what state* a task is in but never *what
/// it is for*, which is the wrong trade for a tree that is seven goals and two
/// hundred descendants: the states are mostly empty and the goal is the thing
/// carrying the meaning. Rows by goal, columns by state, reads the whole
/// commitment at once — which goal is overloaded, which has nothing moving.
public enum KanbanSwimlanes {

  /// The outermost ancestor of `task`, or `nil` when the task is itself
  /// top-level.
  ///
  /// Walks to the root rather than reading a stored depth, because a task's
  /// level is not always populated and a reparent updates the parent long
  /// before anything recomputes a depth. Cycle-guarded for the same reason
  /// `TaskFilterEngine.isDescendant` is: this runs during a cache rebuild on
  /// the main actor, and an unguarded walk freezes the app rather than merely
  /// drawing the wrong row.
  public static func topLevelAncestor<Task: VisibilityTask>(
    of task: Task,
    taskById: [Int: Task]
  ) -> Task? {
    var currentParentId = task.parentId ?? 0
    var ancestor: Task?
    var seen: Set<Int> = [task.id]
    while currentParentId != 0, seen.insert(currentParentId).inserted {
      guard let parent = taskById[currentParentId] else { break }
      ancestor = parent
      currentParentId = parent.parentId ?? 0
    }
    return ancestor
  }

  /// The board's rows, in `laneOrder` first and then by the order the
  /// remaining goals were encountered.
  ///
  /// Lanes with no tasks are dropped: an empty row is a row of empty columns,
  /// which is a lot of screen for "nothing here".
  public static func lanes<Task: VisibilityTask>(
    for tasks: [Task],
    taskById: [Int: Task],
    laneOrder: [Int] = [],
    unassignedTitle: String = "No goal"
  ) -> [KanbanSwimlane<Task>] {
    var tasksByLane: [Int: [Task]] = [:]
    var titleByLane: [Int: String] = [:]
    var encountered: [Int] = []

    for task in tasks {
      let ancestor = topLevelAncestor(of: task, taskById: taskById)
      let laneId = ancestor?.id ?? 0
      if tasksByLane[laneId] == nil {
        tasksByLane[laneId] = []
        titleByLane[laneId] = ancestor?.content ?? unassignedTitle
        encountered.append(laneId)
      }
      tasksByLane[laneId]?.append(task)
    }

    let ordered = laneOrder.filter { tasksByLane[$0] != nil }
      + encountered.filter { !laneOrder.contains($0) }

    return ordered.compactMap { laneId in
      guard let laneTasks = tasksByLane[laneId], !laneTasks.isEmpty else { return nil }
      return KanbanSwimlane(
        id: laneId,
        title: titleByLane[laneId] ?? unassignedTitle,
        tasks: laneTasks
      )
    }
  }
}
