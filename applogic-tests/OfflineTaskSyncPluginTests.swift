import XCTest

@testable import TaktAppLogic

@MainActor
final class OfflineTaskSyncPluginTests: XCTestCase {
  private var defaults: UserDefaults!
  private var localStore: LocalTaskStore!
  private var plugin: OfflineTaskSyncPlugin!

  private let credentials = CheckvistCredentials(username: "u", remoteKey: "k")

  override func setUp() async throws {
    try await super.setUp()
    defaults = makeIsolatedDefaults()
    localStore = LocalTaskStore(defaults: defaults)
    plugin = OfflineTaskSyncPlugin(localStore: localStore)
  }

  func testCreateTaskAssignsAscendingIds() async throws {
    let first = try await plugin.createTask(
      listId: "", content: "alpha", parentId: nil, position: nil, credentials: credentials)
    let second = try await plugin.createTask(
      listId: "", content: "beta", parentId: nil, position: nil, credentials: credentials)

    XCTAssertNotNil(first?.id)
    XCTAssertNotNil(second?.id)
    XCTAssertEqual((second?.id ?? 0) - (first?.id ?? 0), 1)
  }

  func testFetchOpenTasksAssignsContiguousPositionsWithinParent() async throws {
    _ = try await plugin.createTask(
      listId: "", content: "root-a", parentId: nil, position: nil, credentials: credentials)
    _ = try await plugin.createTask(
      listId: "", content: "root-b", parentId: nil, position: nil, credentials: credentials)
    let parent = try await plugin.createTask(
      listId: "", content: "root-c", parentId: nil, position: nil, credentials: credentials)
    _ = try await plugin.createTask(
      listId: "", content: "child-1", parentId: parent?.id, position: nil,
      credentials: credentials)
    _ = try await plugin.createTask(
      listId: "", content: "child-2", parentId: parent?.id, position: nil,
      credentials: credentials)

    let tasks = try await plugin.fetchOpenTasks(listId: "", credentials: credentials)

    let rootTasks = tasks.filter { $0.parentId == nil }
    XCTAssertEqual(rootTasks.map(\.position), [1, 2, 3])
    let children = tasks.filter { ($0.parentId ?? 0) == (parent?.id ?? -1) }
    XCTAssertEqual(children.map(\.position), [1, 2])
  }

  func testCloseRemovesTaskAndItsDescendantsFromOpen() async throws {
    let parent = try await plugin.createTask(
      listId: "", content: "parent", parentId: nil, position: nil, credentials: credentials)
    let child = try await plugin.createTask(
      listId: "", content: "child", parentId: parent?.id, position: nil, credentials: credentials)
    _ = try await plugin.createTask(
      listId: "", content: "grandchild", parentId: child?.id, position: nil,
      credentials: credentials)
    _ = try await plugin.createTask(
      listId: "", content: "sibling", parentId: nil, position: nil, credentials: credentials)

    let success = try await plugin.performTaskAction(
      listId: "", taskId: parent?.id ?? -1, action: .close, credentials: credentials)
    XCTAssertTrue(success)

    let openTasks = try await plugin.fetchOpenTasks(listId: "", credentials: credentials)
    XCTAssertEqual(openTasks.count, 1)
    XCTAssertEqual(openTasks.first?.content, "sibling")
  }

  func testReopenRestoresArchivedTaskAsOpen() async throws {
    let parent = try await plugin.createTask(
      listId: "", content: "parent", parentId: nil, position: nil, credentials: credentials)
    _ = try await plugin.performTaskAction(
      listId: "", taskId: parent?.id ?? -1, action: .close, credentials: credentials)

    _ = try await plugin.performTaskAction(
      listId: "", taskId: parent?.id ?? -1, action: .reopen, credentials: credentials)

    let openTasks = try await plugin.fetchOpenTasks(listId: "", credentials: credentials)
    XCTAssertEqual(openTasks.map(\.id), [parent?.id])
    XCTAssertEqual(openTasks.first?.status, 0)
  }

  func testDeleteRemovesTaskAndDescendantsWithoutArchiving() async throws {
    let parent = try await plugin.createTask(
      listId: "", content: "parent", parentId: nil, position: nil, credentials: credentials)
    _ = try await plugin.createTask(
      listId: "", content: "child", parentId: parent?.id, position: nil, credentials: credentials)

    let success = try await plugin.deleteTask(
      listId: "", taskId: parent?.id ?? -1, credentials: credentials)
    XCTAssertTrue(success)

    let openTasks = try await plugin.fetchOpenTasks(listId: "", credentials: credentials)
    XCTAssertTrue(openTasks.isEmpty)

    // Recreate plugin from same store to confirm archive list is also empty (delete != close).
    let reborn = OfflineTaskSyncPlugin(localStore: localStore)
    _ = try await reborn.performTaskAction(
      listId: "", taskId: parent?.id ?? -1, action: .reopen, credentials: credentials)
    let postReopenOpens = try await reborn.fetchOpenTasks(listId: "", credentials: credentials)
    XCTAssertTrue(
      postReopenOpens.isEmpty,
      "Reopening a deleted task must not resurrect it from the archive."
    )
  }

  func testMoveTaskUpdatesPositionAndReshufflesNeighbours() async throws {
    // Create with explicit positions so the move has neighbours to slot between.
    // Tasks created with nil position sort to the end (Int.max), so a moveTask
    // with a finite position would order the moved task ahead of nil-position
    // siblings rather than past them — that surprised me when the test failed.
    let a = try await plugin.createTask(
      listId: "", content: "A", parentId: nil, position: 1, credentials: credentials)
    let b = try await plugin.createTask(
      listId: "", content: "B", parentId: nil, position: 2, credentials: credentials)
    let c = try await plugin.createTask(
      listId: "", content: "C", parentId: nil, position: 3, credentials: credentials)

    _ = try await plugin.moveTask(
      listId: "", taskId: a?.id ?? -1, position: 4, credentials: credentials)

    let openTasks = try await plugin.fetchOpenTasks(listId: "", credentials: credentials)
    XCTAssertEqual(openTasks.map(\.id), [b?.id, c?.id, a?.id])
    XCTAssertEqual(openTasks.map(\.position), [1, 2, 3])
  }

  func testReparentMovesTaskUnderNewParent() async throws {
    let parentA = try await plugin.createTask(
      listId: "", content: "A", parentId: nil, position: nil, credentials: credentials)
    let parentB = try await plugin.createTask(
      listId: "", content: "B", parentId: nil, position: nil, credentials: credentials)
    let child = try await plugin.createTask(
      listId: "", content: "child", parentId: parentA?.id, position: nil, credentials: credentials)

    _ = try await plugin.reparentTask(
      listId: "", taskId: child?.id ?? -1, parentId: parentB?.id, credentials: credentials)

    let openTasks = try await plugin.fetchOpenTasks(listId: "", credentials: credentials)
    let movedChild = try XCTUnwrap(openTasks.first(where: { $0.id == child?.id }))
    XCTAssertEqual(movedChild.parentId, parentB?.id)
  }

  func testUpdateTaskChangesContentWhilePreservingDue() async throws {
    let task = try await plugin.createTask(
      listId: "", content: "old", parentId: nil, position: nil, credentials: credentials)
    _ = try await plugin.updateTask(
      listId: "", taskId: task?.id ?? -1, content: nil, due: "2026-01-01",
      credentials: credentials)
    _ = try await plugin.updateTask(
      listId: "", taskId: task?.id ?? -1, content: "new", due: nil, credentials: credentials)

    let openTasks = try await plugin.fetchOpenTasks(listId: "", credentials: credentials)
    let updated = try XCTUnwrap(openTasks.first(where: { $0.id == task?.id }))
    XCTAssertEqual(updated.content, "new")
    XCTAssertEqual(updated.due, "2026-01-01")
  }

  func testWritesReadArchiveAndIdCounterFromStoreRewrittenUnderneath() async throws {
    let doomed = try await plugin.createTask(
      listId: "", content: "closed before the overwrite", parentId: nil, position: nil,
      credentials: credentials)
    _ = try await plugin.performTaskAction(
      listId: "", taskId: doomed?.id ?? -1, action: .close, credentials: credentials)
    XCTAssertEqual(localStore.load().archivedTasks.map(\.id), [doomed?.id])

    // "Keep Remote (Overwrite Local)" saves a fresh payload with no archive
    // behind the plugin's back; the plugin was constructed before this.
    localStore.save(
      OfflineTaskStorePayload(
        openTasks: [makeTask(id: 40, content: "remote")], archivedTasks: [], nextTaskId: 41))

    _ = try await plugin.updateTask(
      listId: "", taskId: 40, content: "remote, renamed", due: nil, credentials: credentials)
    XCTAssertTrue(
      localStore.load().archivedTasks.isEmpty,
      "A write after the overwrite must not put the old archive back.")
    XCTAssertEqual(localStore.load().nextTaskId, 41)

    let created = try await plugin.createTask(
      listId: "", content: "new", parentId: nil, position: nil, credentials: credentials)
    XCTAssertEqual(created?.id, 41, "Ids continue from the stored counter, not the one at init.")

    _ = try await plugin.performTaskAction(
      listId: "", taskId: doomed?.id ?? -1, action: .reopen, credentials: credentials)
    let openTasks = try await plugin.fetchOpenTasks(listId: "", credentials: credentials)
    XCTAssertEqual(
      openTasks.map(\.id).sorted(), [40, 41],
      "Reopening an id the overwrite discarded must not resurrect it.")
  }

  func testFetchListsIsAlwaysEmptyAndLoginAlwaysSucceeds() async throws {
    let lists = try await plugin.fetchLists(credentials: credentials)
    XCTAssertTrue(lists.isEmpty)
    let didLogin = try await plugin.login(credentials: credentials)
    XCTAssertTrue(didLogin)
  }
}
