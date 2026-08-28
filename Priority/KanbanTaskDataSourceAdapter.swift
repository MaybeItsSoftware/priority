import Foundation
import PriorityCore

/// Satisfies `KanbanManager`'s `KanbanTaskDataSource` requirement by reading
/// from the concrete state owners — `TaskRepository` (tasks),
/// `NavigationState` (tree cursor), and `TaskListViewModel` (view-shaping +
/// derived cache) — instead of routing through `AppCoordinator`'s forwarder
/// properties.
///
/// This is what lets the `tasks` / `currentParentId` / `currentSiblingIndex` /
/// `rootTaskView` / `hideFuture` / `cache` forwarders be deleted from
/// `AppCoordinator`: the kanban layer no longer depends on the coordinator
/// conforming to the protocol. `KanbanManager`'s body is unchanged — it still
/// talks to a `KanbanTaskDataSource`; only the object behind it changed.
@MainActor
final class KanbanTaskDataSourceAdapter: KanbanTaskDataSource {
  private let repository: TaskRepository
  private let navigationState: NavigationState
  private let taskListViewModel: TaskListViewModel

  init(
    repository: TaskRepository,
    navigationState: NavigationState,
    taskListViewModel: TaskListViewModel
  ) {
    self.repository = repository
    self.navigationState = navigationState
    self.taskListViewModel = taskListViewModel
  }

  var tasks: [CheckvistTask] { repository.tasks }

  var currentParentId: Int {
    get { navigationState.currentParentId }
    set { navigationState.currentParentId = newValue }
  }

  var currentSiblingIndex: Int {
    get { navigationState.currentSiblingIndex }
    set { navigationState.currentSiblingIndex = newValue }
  }

  var hideFuture: Bool { taskListViewModel.hideFuture }
  var showChildrenInMenus: Bool { taskListViewModel.showChildrenInMenus }
  var rootTaskView: RootTaskView { taskListViewModel.rootTaskView }
  var cache: CacheState { taskListViewModel.cache }

  func ensureVisibleTasksCacheValid() {
    taskListViewModel.ensureVisibleTasksCacheValid()
  }

  func rootDueBucket(for task: CheckvistTask) -> RootDueBucket {
    taskListViewModel.rootDueBucket(for: task)
  }

  func absolutePriorityRank(for task: CheckvistTask) -> Int? {
    taskListViewModel.ensureVisibleTasksCacheValid()
    return taskListViewModel.cache.absolutePriorityRank[task.id]
  }

  func priorityRank(for task: CheckvistTask) -> Int? {
    taskListViewModel.ensureVisibleTasksCacheValid()
    return taskListViewModel.cache.priorityRank[task.id]
  }

  func priorityPath(for task: CheckvistTask) -> String? {
    taskListViewModel.ensureVisibleTasksCacheValid()
    return taskListViewModel.cache.priorityPath[task.id]
  }

  func childCountByTaskId() -> [Int: Int] {
    taskListViewModel.childCountByTaskId()
  }
}
