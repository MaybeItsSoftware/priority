import Foundation

/// Decides which tasks the list shows, and in what order, for every
/// combination of root view, scope filter, search and drill-down level.
///
/// Generic over `VisibilityTask` rather than naming `CheckvistTask`, which is
/// what lets it live in `TaktCore` and be tested directly. Nothing here
/// needs to know where a task came from.
public struct TaskVisibilityEngine {
  public struct Context<Task: VisibilityTask> {
    public let tasks: [Task]
    public let currentLevelTasks: [Task]
    public let currentParentId: Int
    public let isSearchFilterActive: Bool
    public let searchText: String
    public let hideFuture: Bool
    public let shouldShowRootScopeSection: Bool
    public let isRootLevel: Bool
    public let rootTaskView: RootTaskView
    public let showChildrenInMenus: Bool
    public let selectedRootDueBucket: RootDueBucket?
    public let selectedRootTag: String
    public let taskById: [Int: Task]
    public let isDescendant: (Task, Int) -> Bool
    public let taskMatchesActiveRootScope: (Task) -> Bool
    public let isAbsolutePrioritized: (Task) -> Bool
    public let compareByPriorityThenPosition: (Task, Task) -> Bool
    public let compareByRootDueBucket: (Task, Task) -> Bool
    public let hasAnyTag: (Task) -> Bool
    public let hasTag: (Task, String) -> Bool
    public let rootDueBucket: (Task) -> RootDueBucket

    // Spelled out because the memberwise initialiser is internal, and the app
    // builds this from across the module boundary.
    public init(
      tasks: [Task],
      currentLevelTasks: [Task],
      currentParentId: Int,
      isSearchFilterActive: Bool,
      searchText: String,
      hideFuture: Bool,
      shouldShowRootScopeSection: Bool,
      isRootLevel: Bool,
      rootTaskView: RootTaskView,
      showChildrenInMenus: Bool,
      selectedRootDueBucket: RootDueBucket?,
      selectedRootTag: String,
      taskById: [Int: Task],
      isDescendant: @escaping (Task, Int) -> Bool,
      taskMatchesActiveRootScope: @escaping (Task) -> Bool,
      isAbsolutePrioritized: @escaping (Task) -> Bool,
      compareByPriorityThenPosition: @escaping (Task, Task) -> Bool,
      compareByRootDueBucket: @escaping (Task, Task) -> Bool,
      hasAnyTag: @escaping (Task) -> Bool,
      hasTag: @escaping (Task, String) -> Bool,
      rootDueBucket: @escaping (Task) -> RootDueBucket
    ) {
      self.tasks = tasks
      self.currentLevelTasks = currentLevelTasks
      self.currentParentId = currentParentId
      self.isSearchFilterActive = isSearchFilterActive
      self.searchText = searchText
      self.hideFuture = hideFuture
      self.shouldShowRootScopeSection = shouldShowRootScopeSection
      self.isRootLevel = isRootLevel
      self.rootTaskView = rootTaskView
      self.showChildrenInMenus = showChildrenInMenus
      self.selectedRootDueBucket = selectedRootDueBucket
      self.selectedRootTag = selectedRootTag
      self.taskById = taskById
      self.isDescendant = isDescendant
      self.taskMatchesActiveRootScope = taskMatchesActiveRootScope
      self.isAbsolutePrioritized = isAbsolutePrioritized
      self.compareByPriorityThenPosition = compareByPriorityThenPosition
      self.compareByRootDueBucket = compareByRootDueBucket
      self.hasAnyTag = hasAnyTag
      self.hasTag = hasTag
      self.rootDueBucket = rootDueBucket
    }
  }

  public struct Result<Task: VisibilityTask> {
    public let tasks: [Task]
    /// Index at which non-matching "remainder" tasks begin. nil when the view
    /// does not split matching / remainder.
    public let remainderStartIndex: Int?

    public init(
      tasks: [Task],
      remainderStartIndex: Int?
    ) {
    self.tasks = tasks
    self.remainderStartIndex = remainderStartIndex
    }
  }

  public static func computeVisibleTasks<Task: VisibilityTask>(in context: Context<Task>) -> [Task] {
    compute(in: context).tasks
  }

  public static func compute<Task: VisibilityTask>(in context: Context<Task>) -> Result<Task> {
    if context.isSearchFilterActive {
      var matches = context.tasks.filter { task in
        task.content.localizedCaseInsensitiveContains(context.searchText)
          && context.isDescendant(task, context.currentParentId)
      }
      matches.sort(by: context.compareByPriorityThenPosition)
      return Result(tasks: matches, remainderStartIndex: nil)
    }

    let baseTasks: [Task]
    if context.shouldShowRootScopeSection {
      if context.isRootLevel {
        switch context.rootTaskView {
        case .all:
          // The "main list" stays scoped to current-level siblings regardless of
          // the show-children toggle; users rely on it for hierarchical navigation.
          baseTasks = context.currentLevelTasks
        case .due, .tags, .priority:
          // One rule for all three. Priority used to answer the toggle with
          // `context.tasks` — the *entire list*, scope ignored — so a sibling
          // branch showed up in a view the user had deliberately scoped, and
          // the same toggle meant two different things depending on the tab.
          baseTasks = TaskScopeResolver.scoped(
            context.tasks,
            currentLevelTasks: context.currentLevelTasks,
            parentId: context.currentParentId,
            mode: TaskScopeResolver.mode(showChildrenInMenus: context.showChildrenInMenus),
            isDescendant: context.isDescendant
          )
        case .kanban, .eisenhower, .daily:
          // These render their own surface rather than the task list — kanban
          // has per-column lists via tasksForKanbanColumn, and Daily reads the
          // log. `visibleTasks` is unused in all three, so return empty to
          // prevent any stale-index interaction with currentSiblingIndex.
          return Result(tasks: [], remainderStartIndex: nil)
        }
      } else {
        switch context.rootTaskView {
        case .all:
          baseTasks = context.currentLevelTasks
        case .due, .tags, .priority, .kanban, .eisenhower, .daily:
          baseTasks = TaskScopeResolver.scoped(
            context.tasks,
            currentLevelTasks: context.currentLevelTasks,
            parentId: context.currentParentId,
            mode: TaskScopeResolver.mode(showChildrenInMenus: context.showChildrenInMenus),
            isDescendant: context.isDescendant
          )
        }
      }
    } else {
      baseTasks = context.currentLevelTasks
    }

    var result = baseTasks
    if context.hideFuture {
      result = result.filter { task in
        guard let dueDate = task.dueDate else { return false }
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) else {
          return false
        }
        return dueDate <= Calendar.current.startOfDay(for: tomorrow)
      }
    }

    if context.shouldShowRootScopeSection {
      if context.isRootLevel {
        switch context.rootTaskView {
        case .all:
          result.sort(by: context.compareByPriorityThenPosition)
        case .due:
          let matchesFilter: (Task) -> Bool = { task in
            if let selectedRootDueBucket = context.selectedRootDueBucket {
              return context.rootDueBucket(task) == selectedRootDueBucket
            }
            return context.rootDueBucket(task) != .noDueDate
          }
          var matching = result.filter(matchesFilter)
          matching.sort(by: context.compareByRootDueBucket)
          return Result(tasks: matching, remainderStartIndex: nil)
        case .tags:
          let matchesFilter: (Task) -> Bool = { task in
            if context.selectedRootTag.isEmpty { return context.hasAnyTag(task) }
            return context.hasTag(task, context.selectedRootTag)
          }
          var matching = result.filter(matchesFilter)
          matching.sort(by: context.compareByPriorityThenPosition)
          return Result(tasks: matching, remainderStartIndex: nil)
        case .priority:
          var matching = result.filter { context.taskMatchesActiveRootScope($0) }
          // When an ancestor is also prioritised, only show the ancestor at root.
          // Users can drill in to see prioritised descendants in that subtree.
          let prioritizedIds = Set(matching.map(\.id))
          matching = matching.filter { task in
            let taskIsAbsolute = context.isAbsolutePrioritized(task)
            var parentId = task.parentId ?? 0
            // See `TaskFilterEngine.isDescendant`: a parent cycle would spin
            // here forever, on the main actor, during a cache rebuild.
            var seen: Set<Int> = []
            while parentId != 0, seen.insert(parentId).inserted {
              if prioritizedIds.contains(parentId) {
                // Absolute priority can break out of a scoped-priority ancestor.
                if taskIsAbsolute,
                  let ancestor = context.taskById[parentId],
                  !context.isAbsolutePrioritized(ancestor)
                {
                  parentId = context.taskById[parentId]?.parentId ?? 0
                  continue
                }
                return false
              }
              parentId = context.taskById[parentId]?.parentId ?? 0
            }
            return true
          }
          matching.sort(by: context.compareByPriorityThenPosition)
          return Result(tasks: matching, remainderStartIndex: nil)
        case .kanban, .eisenhower, .daily:
          break  // unreachable — these return [] above
        }
      } else {
        // Sub-level in a filtered root tab.
        switch context.rootTaskView {
        case .all, .kanban, .eisenhower, .daily:
          result.sort(by: context.compareByPriorityThenPosition)
        case .tags:
          var matching = result.filter(context.taskMatchesActiveRootScope)
          matching.sort(by: context.compareByPriorityThenPosition)
          return Result(tasks: matching, remainderStartIndex: nil)
        case .due:
          var matching = result.filter(context.taskMatchesActiveRootScope)
          matching.sort(by: context.compareByRootDueBucket)
          return Result(tasks: matching, remainderStartIndex: nil)
        case .priority:
          var matching = result.filter(context.taskMatchesActiveRootScope)
          matching.sort(by: context.compareByPriorityThenPosition)
          return Result(tasks: matching, remainderStartIndex: nil)
        }
      }
    } else {
      result.sort(by: context.compareByPriorityThenPosition)
    }
    return Result(tasks: result, remainderStartIndex: nil)
  }
}
