import XCTest

@testable import TaktAppLogic

final class ListScopedTaskIDStoreTests: XCTestCase {
  func testRoundTripsForSingleScope() {
    let store = ListScopedTaskIDStore(defaultsKey: "k", defaults: makeIsolatedDefaults())
    store.save([3, 1, 2], for: "list-a")
    XCTAssertEqual(store.load(for: "list-a"), [3, 1, 2])
  }

  func testNormalizesDuplicatesAndZeros() {
    let store = ListScopedTaskIDStore(defaultsKey: "k", defaults: makeIsolatedDefaults())
    store.save([1, 0, 2, 1, -3, 2, 4], for: "list-a")
    XCTAssertEqual(store.load(for: "list-a"), [1, 2, 4])
  }

  func testDifferentScopesAreIsolated() {
    let store = ListScopedTaskIDStore(defaultsKey: "k", defaults: makeIsolatedDefaults())
    store.save([1, 2], for: "list-a")
    store.save([10, 20], for: "list-b")
    XCTAssertEqual(store.load(for: "list-a"), [1, 2])
    XCTAssertEqual(store.load(for: "list-b"), [10, 20])
  }

  func testEmptyListIdRoutesToOfflineScope() {
    let defaults = makeIsolatedDefaults()
    let store = ListScopedTaskIDStore(defaultsKey: "k", defaults: defaults)
    store.save([7, 8], for: "")
    let other = ListScopedTaskIDStore(defaultsKey: "k", defaults: defaults)
    XCTAssertEqual(other.load(for: ""), [7, 8])
    XCTAssertEqual(other.load(for: "real-list"), [])
  }

  func testSaveEmptyClearsScope() {
    let store = ListScopedTaskIDStore(defaultsKey: "k", defaults: makeIsolatedDefaults())
    store.save([1, 2, 3], for: "list-a")
    store.save([], for: "list-a")
    XCTAssertEqual(store.load(for: "list-a"), [])
  }

  func testMaximumCountTruncates() {
    let store = ListScopedTaskIDStore(
      defaultsKey: "k", maximumCount: 3, defaults: makeIsolatedDefaults())
    store.save([1, 2, 3, 4, 5], for: "list-a")
    XCTAssertEqual(store.load(for: "list-a"), [1, 2, 3])
  }
}

final class ListScopedPriorityStoreTests: XCTestCase {
  func testRoundTripsPerParentQueues() {
    let store = ListScopedPriorityStore(defaultsKey: "k", defaults: makeIsolatedDefaults())
    let queues: [Int: [Int]] = [0: [1, 2], 5: [10, 11]]
    store.save(queues, for: "list-a")
    XCTAssertEqual(store.load(for: "list-a"), queues)
  }

  func testNormalizesQueuesOnSave() {
    let store = ListScopedPriorityStore(defaultsKey: "k", defaults: makeIsolatedDefaults())
    store.save([0: [1, 1, 2, -1, 0, 3]], for: "list-a")
    XCTAssertEqual(store.load(for: "list-a")[0], [1, 2, 3])
  }

  func testDifferentListsAreIsolated() {
    let defaults = makeIsolatedDefaults()
    let store = ListScopedPriorityStore(defaultsKey: "k", defaults: defaults)
    store.save([0: [1, 2]], for: "list-a")
    store.save([0: [9, 8]], for: "list-b")
    XCTAssertEqual(store.load(for: "list-a")[0], [1, 2])
    XCTAssertEqual(store.load(for: "list-b")[0], [9, 8])
  }

  func testSavingEmptyClearsScope() {
    let store = ListScopedPriorityStore(defaultsKey: "k", defaults: makeIsolatedDefaults())
    store.save([0: [1, 2]], for: "list-a")
    store.save([:], for: "list-a")
    XCTAssertTrue(store.load(for: "list-a").isEmpty)
  }
}

final class ListScopedEisenhowerStoreTests: XCTestCase {
  func testRoundTripsLevels() {
    let store = ListScopedEisenhowerStore(defaultsKey: "k", defaults: makeIsolatedDefaults())
    let levels: [Int: EisenhowerLevel] = [
      1: EisenhowerLevel(urgency: 0.3, importance: 0.7),
      2: EisenhowerLevel(urgency: 0.9, importance: 0.1),
    ]
    store.save(levels, for: "list-a")
    XCTAssertEqual(store.load(for: "list-a"), levels)
  }

  func testZeroLevelsAreFilteredOut() {
    let store = ListScopedEisenhowerStore(defaultsKey: "k", defaults: makeIsolatedDefaults())
    store.save(
      [
        1: .zero,
        2: EisenhowerLevel(urgency: 0.5, importance: 0.5),
      ],
      for: "list-a"
    )
    let loaded = store.load(for: "list-a")
    XCTAssertNil(loaded[1])
    XCTAssertEqual(loaded[2]?.urgency, 0.5)
  }

  func testListsAreIsolated() {
    let defaults = makeIsolatedDefaults()
    let store = ListScopedEisenhowerStore(defaultsKey: "k", defaults: defaults)
    store.save([1: EisenhowerLevel(urgency: 0.4, importance: 0.4)], for: "list-a")
    store.save([1: EisenhowerLevel(urgency: 0.9, importance: 0.9)], for: "list-b")
    XCTAssertEqual(store.load(for: "list-a")[1]?.urgency, 0.4)
    XCTAssertEqual(store.load(for: "list-b")[1]?.urgency, 0.9)
  }
}
