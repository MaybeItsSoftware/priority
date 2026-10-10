import Synchronization
import XCTest

@testable import TaktAppLogic
@testable import TaktCore

/// `TaskListViewModel` decides what every list view renders, and owns
/// `cacheVersion`, whose whole job is to be correct about SwiftUI observation.
/// None of it could be reached from a test: the type named five app-only
/// managers concretely, and `TaktAppLogic` could not import `TaktCore`
/// for the visibility engines it uses. Both are now false — the app links the
/// package rather than compiling it — so this is the first coverage it has had.
@MainActor
final class TaskListViewModelTests: XCTestCase {

  /// A stand-in for the managers. Every member is a read the view model
  /// makes, which is the whole surface `TaskListViewModelHost` describes.
  private final class StubHost: TaskListViewModelHost {
    var currentParentId = 0
    var currentSiblingIndex = 0
    var isSearchFilterActive = false
    var searchText = ""
    var matrixSelectedTaskId: Int?
  }

  private var defaults: UserDefaults!
  private var preferencesStore: PreferencesStore!

  override func setUp() {
    super.setUp()
    defaults = makeIsolatedDefaults()
    preferencesStore = PreferencesStore(defaults: defaults)
  }

  private func makeViewModel(
    tasks: [CheckvistTask] = []
  ) -> (TaskListViewModel, StubHost, TaskRepository) {
    let repository = TaskRepository(
      preferencesStore: preferencesStore,
      checkvistSyncPlugin: FakeCheckvistSyncPlugin(),
      localTaskStore: LocalTaskStore(defaults: defaults),
      initialRemoteKey: "",
      defaults: defaults
    )
    repository.tasks = tasks
    let host = StubHost()
    let viewModel = TaskListViewModel(
      repository: repository,
      preferencesStore: preferencesStore,
      host: host
    )
    return (viewModel, host, repository)
  }

  /// `withObservationTracking`'s `onChange` is not actor-isolated, so the flag
  /// it sets cannot be a captured local.
  private final class Observed: Sendable {
    let fired = Mutex(false)
  }

  private func task(
    _ id: Int, _ content: String, parentId: Int? = nil, position: Int? = nil, due: String? = nil
  ) -> CheckvistTask {
    CheckvistTask(
      id: id, content: content, status: 0, due: due, position: position ?? id,
      parentId: parentId)
  }

  // MARK: - Observation

  /// The fix this test exists for. `visibleTasks` used to touch ten
  /// `repository` properties by hand so SwiftUI would register a dependency on
  /// each; miss one and the list silently stopped updating. `cacheVersion`
  /// replaced that list — one observable value that changes whenever the cache
  /// is invalidated.
  func testInvalidatingTheCacheBumpsTheObservedVersion() {
    let (viewModel, _, _) = makeViewModel(tasks: [task(1, "a")])
    let before = viewModel.cacheVersion

    viewModel.invalidateCaches()

    XCTAssertNotEqual(viewModel.cacheVersion, before)
  }

  /// The subtle half. A view that reads a *clean* cache must still register a
  /// dependency on it, or it renders once and never updates again. The read of
  /// `cacheVersion` therefore has to happen before the early return, not after
  /// — which is invisible in the code and impossible to catch by eye.
  func testReadingACleanCacheStillObservesTheVersion() {
    let (viewModel, _, _) = makeViewModel(tasks: [task(1, "a")])
    _ = viewModel.visibleTasks  // rebuild, leaving the cache clean

    let observed = Observed()
    withObservationTracking {
      viewModel.ensureVisibleTasksCacheValid()
    } onChange: {
      observed.fired.withLock { $0 = true }
    }

    // Invalidated directly: the repository reaches the view model through
    // `CacheInvalidationBus`, which `AppCoordinator` wires up, and this test
    // is about the observation itself rather than that wiring.
    viewModel.invalidateCaches()

    XCTAssertTrue(
      observed.fired.withLock { $0 },
      "a view that read the cache while it was clean never hears about the next change")
  }

  /// The reason the rebuild is deferred at all: one delete touches `tasks`,
  /// both priority queues and the eisenhower levels, and should cost one
  /// recompute rather than four.
  func testABurstOfInvalidationsCostsOneRebuild() {
    let (viewModel, _, _) = makeViewModel(tasks: [task(1, "a"), task(2, "b")])
    _ = viewModel.visibleTasks

    let start = viewModel.cacheVersion
    viewModel.invalidateCaches()
    viewModel.invalidateCaches()
    viewModel.invalidateCaches()
    XCTAssertEqual(viewModel.cacheVersion, start &+ 3, "every write is observed")

    let afterWrites = viewModel.cacheVersion
    _ = viewModel.visibleTasks
    _ = viewModel.visibleTasks
    XCTAssertEqual(
      viewModel.cacheVersion, afterWrites,
      "reads rebuild at most once and do not themselves invalidate")
  }

  // MARK: - Visibility

  func testTheRootLevelShowsOnlyTopLevelTasks() {
    let (viewModel, _, _) = makeViewModel(tasks: [
      task(1, "root"), task(2, "child", parentId: 1), task(3, "other root"),
    ])
    viewModel.rootTaskView = .all

    XCTAssertEqual(viewModel.currentLevelTasks.map(\.id), [1, 3])
  }

  func testDrillingIntoATaskShowsItsChildren() {
    let (viewModel, host, _) = makeViewModel(tasks: [
      task(1, "root"), task(2, "child", parentId: 1), task(3, "other root"),
    ])
    host.currentParentId = 1

    XCTAssertEqual(viewModel.currentLevelTasks.map(\.id), [2])
    XCTAssertFalse(viewModel.isRootLevel)
  }

  func testTheSelectedTaskFollowsTheSiblingIndex() {
    let (viewModel, host, _) = makeViewModel(tasks: [task(1, "a"), task(2, "b")])
    viewModel.rootTaskView = .all
    host.currentSiblingIndex = 1

    XCTAssertEqual(viewModel.currentTask?.id, 2)
  }

  /// An index left pointing past the end after a delete resolves to the last
  /// task rather than trapping.
  func testAnOutOfRangeSiblingIndexClampsInsteadOfCrashing() {
    let (viewModel, host, _) = makeViewModel(tasks: [task(1, "a"), task(2, "b")])
    viewModel.rootTaskView = .all
    host.currentSiblingIndex = 99

    XCTAssertEqual(viewModel.currentTask?.id, 2)
  }

  /// The board and its selection are gone, and `visibleTasks` is deliberately
  /// empty in that view, so a persisted kanban tab selects nothing.
  func testAPersistedKanbanViewSelectsNothing() {
    let (viewModel, _, _) = makeViewModel(tasks: [task(1, "a"), task(2, "b")])
    viewModel.rootTaskView = .kanban

    XCTAssertNil(viewModel.currentTask)
  }

  /// The matrix is not the task list either — `visibleTasks` is empty there by
  /// design — so it needs its own selection.
  /// Without one the plot had none at all: no dot drew selected, `md` answered
  /// "No task selected", and the arrow keys moved something nothing read.
  func testTheMatrixOwnsTheSelectionInMatrixView() {
    let (viewModel, host, _) = makeViewModel(tasks: [task(1, "a"), task(2, "b")])
    host.matrixSelectedTaskId = 2
    viewModel.rootTaskView = .eisenhower

    XCTAssertEqual(viewModel.currentTask?.id, 2)
  }

  func testTheMatrixHasNoSelectionUntilOneIsMade() {
    let (viewModel, _, _) = makeViewModel(tasks: [task(1, "a")])
    viewModel.rootTaskView = .eisenhower

    XCTAssertNil(viewModel.currentTask)
  }

  /// Completing a task takes it off the plot, so it has to take the selection
  /// with it rather than leaving the keys pointed at a dot that is not drawn.
  func testCompletingTheSelectedTaskClearsTheMatrixSelection() {
    let (viewModel, host, repository) = makeViewModel(tasks: [task(1, "a")])
    host.matrixSelectedTaskId = 1
    viewModel.rootTaskView = .eisenhower
    XCTAssertEqual(viewModel.currentTask?.id, 1)

    repository.tasks = [
      CheckvistTask(id: 1, content: "a", status: 1, due: nil, position: 1, parentId: nil)
    ]
    viewModel.invalidateCaches()

    XCTAssertNil(viewModel.currentTask)
  }

  // MARK: - Ancestor walks

  func testIsDescendantWalksTheWholeChain() {
    let (viewModel, _, _) = makeViewModel(tasks: [
      task(1, "a"), task(2, "b", parentId: 1), task(3, "c", parentId: 2),
    ])

    XCTAssertTrue(viewModel.isDescendant(task(3, "c", parentId: 2), of: 1))
    XCTAssertFalse(viewModel.isDescendant(task(1, "a"), of: 3))
  }

  // MARK: - Persisted view state

  /// These write through to the preferences store on set, so the view the user
  /// left in is the one they come back to.
  func testChangingTheRootViewIsPersisted() {
    let (viewModel, _, repository) = makeViewModel()
    viewModel.rootTaskView = .kanban

    let reloaded = TaskListViewModel(
      repository: repository, preferencesStore: preferencesStore)

    XCTAssertEqual(reloaded.rootTaskView, .kanban)
  }
}
