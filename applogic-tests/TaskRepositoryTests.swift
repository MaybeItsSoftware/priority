import XCTest

@testable import PriorityAppLogic

@MainActor
final class TaskRepositoryTests: XCTestCase {
  private var defaults: UserDefaults!
  private var preferencesStore: PreferencesStore!
  private var localTaskStore: LocalTaskStore!
  private var fakePlugin: FakeCheckvistSyncPlugin!

  override func setUp() async throws {
    try await super.setUp()
    defaults = makeIsolatedDefaults()
    preferencesStore = PreferencesStore(defaults: defaults)
    localTaskStore = LocalTaskStore(defaults: defaults)
    fakePlugin = FakeCheckvistSyncPlugin()
  }

  // MARK: Helpers

  private func makeRepository(
    initialUsername: String = "",
    initialListId: String = "",
    initialIntegrationEnabled: Bool? = nil,
    initialOfflineTasks: [CheckvistTask] = [],
    initialRemoteKey: String = ""
  ) -> TaskRepository {
    if !initialUsername.isEmpty {
      preferencesStore.set(initialUsername, for: .checkvistUsername)
    }
    if !initialListId.isEmpty {
      preferencesStore.set(initialListId, for: .checkvistListId)
    }
    if let enabled = initialIntegrationEnabled {
      preferencesStore.set(enabled, for: .checkvistIntegrationEnabled)
    }
    if !initialOfflineTasks.isEmpty {
      localTaskStore.save(
        OfflineTaskStorePayload(
          openTasks: initialOfflineTasks, archivedTasks: [], nextTaskId: 1_000)
      )
    }
    return TaskRepository(
      preferencesStore: preferencesStore,
      checkvistSyncPlugin: fakePlugin,
      localTaskStore: localTaskStore,
      initialRemoteKey: initialRemoteKey,
      defaults: defaults
    )
  }

  // MARK: Boot state

  func testFreshLaunchStartsInOfflineModeWithNoCredentials() {
    let repo = makeRepository()

    XCTAssertFalse(repo.canSyncRemotely)
    XCTAssertFalse(repo.hasCredentials)
    XCTAssertFalse(repo.hasListSelection)
    XCTAssertTrue(repo.activeSyncPlugin is OfflineTaskSyncPlugin)
  }

  func testLegacyCheckvistStateImpliesIntegrationEnabledAtBoot() {
    // No explicit integrationEnabled flag, but stored username + listId implies
    // a returning user from before the flag existed.
    let repo = makeRepository(
      initialUsername: "user@example.com",
      initialListId: "42",
      initialIntegrationEnabled: nil
    )

    XCTAssertTrue(repo.checkvistIntegrationEnabled)
    // Still offline at boot because no remote key was provided.
    XCTAssertFalse(repo.canSyncRemotely)
  }

  func testLaunchWithOfflinePayloadLoadsTasksWhenIntegrationDisabled() {
    let initialTasks = [makeTask(id: 1, content: "leftover")]
    let repo = makeRepository(
      initialIntegrationEnabled: false,
      initialOfflineTasks: initialTasks
    )

    XCTAssertEqual(repo.tasks.map(\.content), ["leftover"])
  }

  func testLaunchWithCredentialsAndListIdRoutesToCheckvistPlugin() {
    let repo = makeRepository(
      initialUsername: "user@example.com",
      initialListId: "42",
      initialIntegrationEnabled: true,
      initialRemoteKey: "remote-key"
    )

    XCTAssertTrue(repo.canSyncRemotely)
    XCTAssertTrue(repo.activeSyncPlugin is FakeCheckvistSyncPlugin)
  }

  // MARK: List switching

  func testChangingListIdReloadsScopedPriorityAndEisenhowerQueues() {
    let repo = makeRepository(initialListId: "list-a")
    repo.savePriorityQueue([0: [10, 20]])
    repo.saveAbsolutePriorityQueue([10])
    repo.saveEisenhowerLevels([10: EisenhowerLevel(urgency: 0.5, importance: 0.5)])

    repo.listId = "list-b"

    XCTAssertTrue(repo.priorityTaskIdsByParentId.isEmpty)
    XCTAssertTrue(repo.absolutePriorityTaskIds.isEmpty)
    XCTAssertTrue(repo.taskEisenhowerLevels.isEmpty)

    repo.listId = "list-a"

    XCTAssertEqual(repo.priorityTaskIdsByParentId[0], [10, 20])
    XCTAssertEqual(repo.absolutePriorityTaskIds, [10])
    XCTAssertEqual(repo.taskEisenhowerLevels[10]?.urgency, 0.5)
  }

  func testChangingListIdPersistsToPreferencesStore() {
    let repo = makeRepository()

    repo.listId = "new-list-id"

    XCTAssertEqual(preferencesStore.string(.checkvistListId), "new-list-id")
  }

  func testChangingListIdInvokesOnListIdChangedCallback() {
    let repo = makeRepository()
    var captured: [String] = []
    repo.onListIdChanged = { captured.append($0) }

    repo.listId = "abc"
    repo.listId = "def"

    XCTAssertEqual(captured, ["abc", "def"])
  }

  // MARK: Online → offline switching

  func testTogglingIntegrationOffMakesRepositoryUseOfflineStore() {
    let repo = makeRepository(
      initialUsername: "user@example.com",
      initialListId: "42",
      initialIntegrationEnabled: true,
      initialRemoteKey: "k"
    )
    XCTAssertTrue(repo.canSyncRemotely)

    repo.checkvistIntegrationEnabled = false

    XCTAssertFalse(repo.canSyncRemotely)
    XCTAssertTrue(repo.activeSyncPlugin is OfflineTaskSyncPlugin)
  }

  // MARK: Priority queue mutations

  func testSetAbsolutePriorityInsertsAtRequestedRank() {
    let repo = makeRepository(initialListId: "list-a")

    repo.setAbsolutePriority(taskId: 1, rank: 1)
    repo.setAbsolutePriority(taskId: 2, rank: 2)
    repo.setAbsolutePriority(taskId: 3, rank: 1)

    XCTAssertEqual(repo.absolutePriorityTaskIds, [3, 1, 2])
  }

  func testSetAbsolutePriorityMovingExistingTaskCoalescesItsOldEntry() {
    let repo = makeRepository(initialListId: "list-a")
    repo.setAbsolutePriority(taskId: 1, rank: 1)
    repo.setAbsolutePriority(taskId: 2, rank: 2)
    repo.setAbsolutePriority(taskId: 3, rank: 3)

    repo.setAbsolutePriority(taskId: 1, rank: 3)

    XCTAssertEqual(repo.absolutePriorityTaskIds, [2, 3, 1])
  }

  func testClearAbsolutePriorityRemovesTask() {
    let repo = makeRepository(initialListId: "list-a")
    repo.setAbsolutePriority(taskId: 1, rank: 1)
    repo.setAbsolutePriority(taskId: 2, rank: 2)

    repo.clearAbsolutePriority(taskId: 1)

    XCTAssertEqual(repo.absolutePriorityTaskIds, [2])
  }

  func testRemoveTasksFromPriorityQueueDropsRanksButKeepsMatrixPlacements() {
    let repo = makeRepository(initialListId: "list-a")
    repo.savePriorityQueue([0: [1, 2, 3], 5: [10, 11]])
    repo.saveAbsolutePriorityQueue([1, 10])
    repo.saveEisenhowerLevels([
      1: EisenhowerLevel(urgency: 0.5, importance: 0.5),
      10: EisenhowerLevel(urgency: 0.5, importance: 0.5),
    ])
    repo.tasks = [
      makeTask(id: 2, parentId: 0),
      makeTask(id: 3, parentId: 0),
      makeTask(id: 11, parentId: 5),
    ]

    repo.removeTasksFromPriorityQueue([1, 10])

    XCTAssertEqual(repo.priorityTaskIdsByParentId[0], [2, 3])
    XCTAssertEqual(repo.priorityTaskIdsByParentId[5], [11])
    XCTAssertEqual(repo.absolutePriorityTaskIds, [])
    // But *not* their place on the matrix. This runs on an optimistic
    // completion, and dropping the coordinate there made ticking a task a
    // silent destructive edit to the matrix that undo could not reach: the
    // reopen brought the task back and left it unplaced.
    XCTAssertNotNil(repo.taskEisenhowerLevels[1])
    XCTAssertNotNil(repo.taskEisenhowerLevels[10])
  }

  /// A closed task keeps its slot, in the scope it was ranked in — there is no
  /// current parent to read for it, and re-scoping it to the root would move it
  /// somewhere else the moment it was reopened. An open task is still re-scoped
  /// under wherever it has actually been moved to.
  func testReconcilePriorityQueueReScopesOpenTasksAndHoldsClosedOnes() {
    let repo = makeRepository(initialListId: "list-a")
    // Legacy: queue stored under parent 0 but task 11's actual parent is 5.
    repo.savePriorityQueue([0: [1, 11, 99]])
    repo.tasks = [
      makeTask(id: 1, parentId: 0),
      makeTask(id: 11, parentId: 5),
      // 99 has been closed: not in the open list any more.
    ]

    repo.reconcilePriorityQueueWithOpenTasks()

    XCTAssertEqual(repo.priorityTaskIdsByParentId[0], [1, 99])
    XCTAssertEqual(repo.priorityTaskIdsByParentId[5], [11])
  }

  /// An optimistic create's temp id is the one thing that really is gone once
  /// it leaves the list — nothing will ever refer to it again.
  func testReconcilePriorityQueueDropsOptimisticTempIds() {
    let repo = makeRepository(initialListId: "list-a")
    repo.savePriorityQueue([0: [1, -7]])
    repo.tasks = [makeTask(id: 1, parentId: 0)]

    repo.reconcilePriorityQueueWithOpenTasks()

    XCTAssertEqual(repo.priorityTaskIdsByParentId[0], [1])
  }
}
