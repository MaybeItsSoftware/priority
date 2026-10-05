import XCTest

@testable import TaktCore

/// The rules `IntegrationCoordinator` applies to the Obsidian sync queue and
/// the calendar link map. 659 LOC with no coverage; these are the parts of it
/// that decide what gets synced and what gets silently dropped.
final class PendingSyncQueueTests: XCTestCase {

  func testNormalizingKeepsOrderAndDropsDuplicates() {
    XCTAssertEqual(PendingSyncQueue.normalized([3, 1, 3, 2, 1]), [3, 1, 2])
  }

  /// A task that exists only optimistically carries a negative temp id.
  /// Queueing one would name an Obsidian folder after an id the server never
  /// issues.
  func testNormalizingDropsPlaceholderIds() {
    XCTAssertEqual(PendingSyncQueue.normalized([-7, 0, 5]), [5])
  }

  func testEnqueueAppends() {
    XCTAssertEqual(PendingSyncQueue.enqueue(3, into: [1, 2]), [1, 2, 3])
  }

  /// Re-queueing moves the task to the back rather than leaving it in place, so
  /// a repeatedly-edited task cannot starve the rest of the queue.
  func testEnqueueingAnAlreadyQueuedTaskMovesItToTheBack() {
    XCTAssertEqual(PendingSyncQueue.enqueue(1, into: [1, 2, 3]), [2, 3, 1])
  }

  func testEnqueueingAPlaceholderIdIsANoOp() {
    XCTAssertEqual(PendingSyncQueue.enqueue(-1, into: [1, 2]), [1, 2])
  }

  func testDequeueRemovesOnlyThatTask() {
    XCTAssertEqual(PendingSyncQueue.dequeue(2, from: [1, 2, 3]), [1, 3])
  }

  func testDequeueingSomethingAbsentLeavesTheQueueAlone() {
    XCTAssertEqual(PendingSyncQueue.dequeue(9, from: [1, 2]), [1, 2])
  }

  /// The one that matters most: nothing local ever dequeues a task completed on
  /// the web or another machine, so without this it waits in the queue forever.
  func testReconcilingDropsTasksNoLongerOpen() {
    XCTAssertEqual(
      PendingSyncQueue.reconciled([1, 2, 3], withOpenTaskIds: [1, 3]), [1, 3])
  }

  func testReconcilingAgainstNoOpenTasksEmptiesTheQueue() {
    XCTAssertEqual(PendingSyncQueue.reconciled([1, 2], withOpenTaskIds: []), [])
  }

  func testReconcilingPreservesOrder() {
    XCTAssertEqual(
      PendingSyncQueue.reconciled([5, 1, 4], withOpenTaskIds: [1, 4, 5]), [5, 1, 4])
  }

  func testTheMenuBarPrefixIsEmptyWhenNothingIsWaiting() {
    XCTAssertEqual(PendingSyncQueue.menuBarPrefix(count: 0), "")
  }

  func testTheMenuBarPrefixIsUncountedForASingleTask() {
    XCTAssertEqual(PendingSyncQueue.menuBarPrefix(count: 1), "Pending Sync")
  }

  func testTheMenuBarPrefixCountsBeyondOne() {
    XCTAssertEqual(PendingSyncQueue.menuBarPrefix(count: 4), "Pending Sync (4)")
  }
}

final class IntegrationLinkStoreTests: XCTestCase {

  /// Scoping by list is what stops the same task id in two lists — or an id
  /// reused after a list is deleted and recreated — from colliding.
  func testKeysAreScopedByList() {
    XCTAssertNotEqual(
      IntegrationLinkStore.storageKey(taskId: 1, listId: "a"),
      IntegrationLinkStore.storageKey(taskId: 1, listId: "b"))
  }

  func testATaskWithNoListSharesTheOfflineScope() {
    XCTAssertEqual(IntegrationLinkStore.storageKey(taskId: 1, listId: ""), "offline:1")
    XCTAssertEqual(IntegrationLinkStore.storageKey(taskId: 1, listId: "   "), "offline:1")
  }

  func testListIdsAreTrimmedSoWhitespaceDoesNotForkTheScope() {
    XCTAssertEqual(
      IntegrationLinkStore.storageKey(taskId: 1, listId: " 42 "),
      IntegrationLinkStore.storageKey(taskId: 1, listId: "42"))
  }

  func testRecordingAURLMakesItRetrievable() {
    let links = IntegrationLinkStore.recording(
      eventURL: URL(string: "https://calendar.example/e/1"), taskId: 7, listId: "42", into: [:])

    XCTAssertEqual(
      IntegrationLinkStore.eventLinkURL(taskId: 7, listId: "42", in: links)?.absoluteString,
      "https://calendar.example/e/1")
  }

  /// "We made an event but got no URL back" has to stay distinguishable from
  /// "we never tried" — otherwise the app offers to create a second event.
  func testAnEventRecordedWithoutAURLStillCountsAsLinked() {
    let links = IntegrationLinkStore.recording(
      eventURL: nil, taskId: 7, listId: "42", into: [:])

    XCTAssertTrue(IntegrationLinkStore.hasEventLink(taskId: 7, listId: "42", in: links))
    XCTAssertNil(
      IntegrationLinkStore.eventLinkURL(taskId: 7, listId: "42", in: links),
      "there is nothing to open, which is what the caller is asking")
  }

  func testAnUnlinkedTaskHasNeitherFlagNorURL() {
    XCTAssertFalse(IntegrationLinkStore.hasEventLink(taskId: 7, listId: "42", in: [:]))
    XCTAssertNil(IntegrationLinkStore.eventLinkURL(taskId: 7, listId: "42", in: [:]))
  }

  func testRecordingLeavesOtherTasksUntouched() {
    let existing = IntegrationLinkStore.recording(
      eventURL: URL(string: "https://calendar.example/e/1"), taskId: 1, listId: "42", into: [:])
    let updated = IntegrationLinkStore.recording(
      eventURL: URL(string: "https://calendar.example/e/2"), taskId: 2, listId: "42",
      into: existing)

    XCTAssertEqual(updated.count, 2)
    XCTAssertEqual(
      IntegrationLinkStore.eventLinkURL(taskId: 1, listId: "42", in: updated)?.absoluteString,
      "https://calendar.example/e/1")
  }

  func testRecordingAgainReplacesTheEarlierLink() {
    var links = IntegrationLinkStore.recording(
      eventURL: URL(string: "https://calendar.example/old"), taskId: 1, listId: "42", into: [:])
    links = IntegrationLinkStore.recording(
      eventURL: URL(string: "https://calendar.example/new"), taskId: 1, listId: "42", into: links)

    XCTAssertEqual(links.count, 1)
    XCTAssertEqual(
      IntegrationLinkStore.eventLinkURL(taskId: 1, listId: "42", in: links)?.absoluteString,
      "https://calendar.example/new")
  }

  func testAGarbledStoredValueYieldsNoURLRatherThanCrashing() {
    let links = ["42:7": ""]
    XCTAssertNil(IntegrationLinkStore.eventLinkURL(taskId: 7, listId: "42", in: links))
  }
}
