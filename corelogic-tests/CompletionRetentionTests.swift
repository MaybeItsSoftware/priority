import XCTest

@testable import PriorityCore

/// Completing a task used to delete both its place on the matrix and its slot
/// in the priority queue, and undo had nothing to say about either — undo
/// covers the task mutation, not the judgements the mutation destroyed on the
/// way past.
final class CompletionRetentionTests: XCTestCase {

  func testCompletingATaskKeepsItsPlaceOnTheMatrix() {
    let retained = CompletionRetention.retained(
      storedIds: [1, 2, 3], openTaskIds: [1, 3])

    XCTAssertEqual(retained, [1, 2, 3])
  }

  /// The one id that really is gone for good: an offline create's temp id, once
  /// the server has answered with a real one.
  func testAnOptimisticTempIdIsDroppedOnceItLeavesTheList() {
    let retained = CompletionRetention.retained(
      storedIds: [-7, 4], openTaskIds: [4])

    XCTAssertEqual(retained, [4])
  }

  func testATempIdStillInTheListIsKept() {
    let retained = CompletionRetention.retained(
      storedIds: [-7, 4], openTaskIds: [-7, 4])

    XCTAssertEqual(retained, [-7, 4])
  }

  /// An empty task list is the state before the first fetch lands, not a list
  /// with nothing in it. Pruning against it would have wiped the whole store.
  func testNothingIsPrunedBeforeTheFirstFetch() {
    let retained = CompletionRetention.retained(
      storedIds: [-7, 1, 2], openTaskIds: [])

    XCTAssertEqual(retained, [-7, 1, 2])
  }

  func testAnEmptyStoreStaysEmpty() {
    XCTAssertEqual(CompletionRetention.retained(storedIds: [], openTaskIds: [1]), [])
  }
}
