import XCTest

@testable import TaktAppLogic

@MainActor
final class ReorderQueueTests: XCTestCase {
  func testEnqueueAppendsRequest() {
    let queue = ReorderQueue()

    queue.enqueue(taskId: 1, position: 5)
    queue.enqueue(taskId: 2, position: 7)

    XCTAssertEqual(queue.pending.map(\.taskId), [1, 2])
    XCTAssertEqual(queue.pending.map(\.position), [5, 7])
  }

  func testEnqueueCoalescesPerTaskKeepingLatestPosition() {
    let queue = ReorderQueue()

    queue.enqueue(taskId: 1, position: 5)
    queue.enqueue(taskId: 2, position: 6)
    queue.enqueue(taskId: 1, position: 99)

    XCTAssertEqual(queue.pending.map(\.taskId), [2, 1])
    XCTAssertEqual(queue.pending.last?.position, 99)
  }

  func testDequeueNextReturnsAndRemovesHead() {
    let queue = ReorderQueue()
    queue.enqueue(taskId: 1, position: 1)
    queue.enqueue(taskId: 2, position: 2)

    let head = queue.dequeueNext()

    XCTAssertEqual(head?.taskId, 1)
    XCTAssertEqual(queue.pending.map(\.taskId), [2])
  }

  func testDequeueNextOnEmptyReturnsNil() {
    let queue = ReorderQueue()
    XCTAssertNil(queue.dequeueNext())
  }

  func testCancelAllClearsPendingAndCancelsTasks() {
    let queue = ReorderQueue()
    queue.enqueue(taskId: 1, position: 1)
    queue.setSyncTask(Task { })
    queue.setResyncTask(Task { })

    queue.cancelAll()

    XCTAssertTrue(queue.pending.isEmpty)
    XCTAssertFalse(queue.isSyncing)
  }
}
