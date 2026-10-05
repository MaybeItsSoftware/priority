import XCTest

@testable import TaktAppLogic

final class LocalTaskStoreTests: XCTestCase {
  func testLoadReturnsEmptyWhenNothingPersisted() {
    let defaults = makeIsolatedDefaults()
    let store = LocalTaskStore(defaults: defaults)

    let payload = store.load()

    XCTAssertTrue(payload.openTasks.isEmpty)
    XCTAssertTrue(payload.archivedTasks.isEmpty)
    XCTAssertEqual(payload.nextTaskId, 1)
  }

  func testSaveThenLoadRoundTrips() {
    let defaults = makeIsolatedDefaults()
    let store = LocalTaskStore(defaults: defaults)
    let payload = OfflineTaskStorePayload(
      openTasks: [makeTask(id: 1, content: "alpha")],
      archivedTasks: [makeTask(id: 2, content: "beta", status: 1)],
      nextTaskId: 42
    )

    store.save(payload)
    let loaded = store.load()

    XCTAssertEqual(loaded.openTasks.map(\.id), [1])
    XCTAssertEqual(loaded.archivedTasks.map(\.id), [2])
    XCTAssertEqual(loaded.nextTaskId, 42)
  }

  func testCorruptDataFallsBackToEmpty() {
    let defaults = makeIsolatedDefaults()
    defaults.set(Data("not-json".utf8), forKey: "offlineTaskStorePayload")
    let store = LocalTaskStore(defaults: defaults)

    let payload = store.load()

    XCTAssertEqual(payload.openTasks.count, 0)
    XCTAssertEqual(payload.nextTaskId, 1)
  }
}
