import XCTest

@testable import TaktCore

final class OfflineReplayPolicyTests: XCTestCase {
  func testRealIdsPassThroughUnchanged() {
    XCTAssertEqual(
      OfflineReplayPolicy.resolve(
        taskId: 4321, tempIdToRealId: [:], requeuedCreateTempIds: []),
      .send(taskId: 4321)
    )
  }

  func testTempIdMapsToServerIdOnceItsCreateSucceeded() {
    XCTAssertEqual(
      OfflineReplayPolicy.resolve(
        taskId: -7, tempIdToRealId: [-7: 900], requeuedCreateTempIds: []),
      .send(taskId: 900)
    )
  }

  /// The regression this policy exists for: a create that failed mid-flush is
  /// retried on the next one, so dependent work must survive rather than being
  /// treated as moot. Dropping it here resurrected tasks the user had already
  /// deleted or completed offline.
  func testWorkBehindARequeuedCreateIsPreservedNotDropped() {
    XCTAssertEqual(
      OfflineReplayPolicy.resolve(
        taskId: -7, tempIdToRealId: [:], requeuedCreateTempIds: [-7]),
      .requeue(tempId: -7)
    )
  }

  func testRequeuedCreateTakesPrecedenceOverAStaleSuccessMapping() {
    XCTAssertEqual(
      OfflineReplayPolicy.resolve(
        taskId: -7, tempIdToRealId: [-7: 900], requeuedCreateTempIds: [-7]),
      .requeue(tempId: -7)
    )
  }

  func testWorkBehindAVanishedCreateIsDropped() {
    XCTAssertEqual(
      OfflineReplayPolicy.resolve(
        taskId: -7, tempIdToRealId: [-1: 900], requeuedCreateTempIds: [-2]),
      .drop
    )
  }

  func testUnrelatedTempIdsDoNotInterfere() {
    let tempIdToRealId = [-1: 100, -2: 200]
    let requeued: Set<Int> = [-3]

    XCTAssertEqual(
      OfflineReplayPolicy.resolve(
        taskId: -1, tempIdToRealId: tempIdToRealId, requeuedCreateTempIds: requeued),
      .send(taskId: 100)
    )
    XCTAssertEqual(
      OfflineReplayPolicy.resolve(
        taskId: -3, tempIdToRealId: tempIdToRealId, requeuedCreateTempIds: requeued),
      .requeue(tempId: -3)
    )
    XCTAssertEqual(
      OfflineReplayPolicy.resolve(
        taskId: -4, tempIdToRealId: tempIdToRealId, requeuedCreateTempIds: requeued),
      .drop
    )
  }
}
