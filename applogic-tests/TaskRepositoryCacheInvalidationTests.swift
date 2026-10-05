import XCTest

@testable import TaktAppLogic

/// Documents which `TaskRepository` mutations fire the shared
/// `CacheInvalidationBus`. Phase 2 of the architecture plan replaced the
/// per-manager `onCacheRelevantChange` callback with the bus and added the
/// previously-missing `didSet`s on `availableLists` and `isNetworkReachable`,
/// so the formerly-known-failing cases below now pass.
@MainActor
final class TaskRepositoryCacheInvalidationTests: XCTestCase {
  private var defaults: UserDefaults!
  private var bus: CacheInvalidationBus!
  private var repo: TaskRepository!
  private var fired = 0

  override func setUp() async throws {
    try await super.setUp()
    defaults = makeIsolatedDefaults()
    let preferencesStore = PreferencesStore(defaults: defaults)
    let localTaskStore = LocalTaskStore(defaults: defaults)
    bus = CacheInvalidationBus()
    repo = TaskRepository(
      preferencesStore: preferencesStore,
      checkvistSyncPlugin: FakeCheckvistSyncPlugin(),
      localTaskStore: localTaskStore,
      initialRemoteKey: "",
      cacheInvalidationBus: bus,
      defaults: defaults
    )
    fired = 0
    bus.subscribe { [weak self] in self?.fired += 1 }
  }

  func testMutatingTasksFiresInvalidation() {
    repo.tasks = [makeTask(id: 1)]
    XCTAssertEqual(fired, 1)
  }

  func testMutatingPriorityTaskIdsByParentIdFiresInvalidation() {
    repo.priorityTaskIdsByParentId = [0: [1, 2]]
    XCTAssertEqual(fired, 1)
  }

  func testMutatingAbsolutePriorityTaskIdsFiresInvalidation() {
    repo.absolutePriorityTaskIds = [1, 2]
    XCTAssertEqual(fired, 1)
  }

  func testMutatingTaskEisenhowerLevelsFiresInvalidation() {
    repo.taskEisenhowerLevels = [1: EisenhowerLevel(urgency: 0.5, importance: 0.5)]
    XCTAssertEqual(fired, 1)
  }

  func testMutatingAvailableListsFiresInvalidation() {
    repo.availableLists = [
      CheckvistList(id: 1, name: "Inbox", archived: false, readOnly: false)
    ]
    XCTAssertEqual(fired, 1)
  }

  func testMutatingIsNetworkReachableFiresInvalidation() {
    repo.isNetworkReachable = false
    XCTAssertEqual(fired, 1)
  }
}
