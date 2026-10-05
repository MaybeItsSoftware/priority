import XCTest

@testable import TaktCore

final class TimerElapsedReassignmentPolicyTests: XCTestCase {
  func testRemovedChildElapsedRollsIntoOpenParent() {
    let previousNodes = [
      TimerNode(id: 1, parentId: nil),
      TimerNode(id: 2, parentId: 1),
    ]
    let latestOpenTaskIDs: Set<Int> = [1]
    let elapsedByTaskID: [Int: TimeInterval] = [2: 120]

    let remapped = TimerElapsedReassignmentPolicy.remapElapsed(
      previousNodes: previousNodes,
      latestOpenTaskIDs: latestOpenTaskIDs,
      elapsedByTaskID: elapsedByTaskID
    )

    XCTAssertEqual(remapped, [1: 120])
  }

  func testRemovedBranchElapsedRollsIntoNearestOpenAncestor() {
    let previousNodes = [
      TimerNode(id: 1, parentId: nil),
      TimerNode(id: 2, parentId: 1),
      TimerNode(id: 3, parentId: 2),
    ]
    let latestOpenTaskIDs: Set<Int> = [1]
    let elapsedByTaskID: [Int: TimeInterval] = [2: 30, 3: 10]

    let remapped = TimerElapsedReassignmentPolicy.remapElapsed(
      previousNodes: previousNodes,
      latestOpenTaskIDs: latestOpenTaskIDs,
      elapsedByTaskID: elapsedByTaskID
    )

    XCTAssertEqual(remapped, [1: 40])
  }

  func testOpenTasksKeepOwnElapsed() {
    let previousNodes = [
      TimerNode(id: 1, parentId: nil),
      TimerNode(id: 2, parentId: 1),
    ]
    let latestOpenTaskIDs: Set<Int> = [1, 2]
    let elapsedByTaskID: [Int: TimeInterval] = [1: 15, 2: 90]

    let remapped = TimerElapsedReassignmentPolicy.remapElapsed(
      previousNodes: previousNodes,
      latestOpenTaskIDs: latestOpenTaskIDs,
      elapsedByTaskID: elapsedByTaskID
    )

    XCTAssertEqual(remapped, elapsedByTaskID)
  }

  func testRemovedRootElapsedDropsWhenNoOpenAncestorExists() {
    let previousNodes = [TimerNode(id: 1, parentId: nil)]
    let latestOpenTaskIDs: Set<Int> = []
    let elapsedByTaskID: [Int: TimeInterval] = [1: 42]

    let remapped = TimerElapsedReassignmentPolicy.remapElapsed(
      previousNodes: previousNodes,
      latestOpenTaskIDs: latestOpenTaskIDs,
      elapsedByTaskID: elapsedByTaskID
    )

    XCTAssertEqual(remapped, [:])
  }
}
