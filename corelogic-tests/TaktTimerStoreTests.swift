import XCTest

@testable import TaktCore

final class TimerStoreTests: XCTestCase {

  // MARK: - formatted()

  func testFormattedSeconds() {
    XCTAssertEqual(TimerStore.formatted(0), "0s")
    XCTAssertEqual(TimerStore.formatted(59), "59s")
  }

  func testFormattedMinutes() {
    XCTAssertEqual(TimerStore.formatted(60), "1.0m")
    XCTAssertEqual(TimerStore.formatted(594), "9.9m")
    XCTAssertEqual(TimerStore.formatted(600), "10m")
    XCTAssertEqual(TimerStore.formatted(3599), "59m")
  }

  func testFormattedHours() {
    XCTAssertEqual(TimerStore.formatted(3600), "1.0h")
    XCTAssertEqual(TimerStore.formatted(35640), "9.9h")
    XCTAssertEqual(TimerStore.formatted(36000), "10h")
  }

  // MARK: - childCountByTaskId()

  func testChildCountByTaskId() {
    let nodes = [
      TimerNode(id: 1, parentId: nil),
      TimerNode(id: 2, parentId: 1),
      TimerNode(id: 3, parentId: 1),
      TimerNode(id: 4, parentId: 2),
    ]
    let counts = TimerStore.childCountByTaskId(nodes: nodes)
    XCTAssertEqual(counts[1], 2)
    XCTAssertEqual(counts[2], 1)
    XCTAssertNil(counts[3])
    XCTAssertNil(counts[4])
  }

  // MARK: - rolledUpElapsedByTaskId()

  func testRolledUpElapsedSumsDescendants() {
    let nodes = [
      TimerNode(id: 1, parentId: nil),
      TimerNode(id: 2, parentId: 1),
      TimerNode(id: 3, parentId: 1),
    ]
    let elapsed: [Int: TimeInterval] = [1: 10, 2: 20, 3: 30]
    let rolled = TimerStore.rolledUpElapsedByTaskId(nodes: nodes, ownElapsed: elapsed)
    XCTAssertEqual(rolled[1], 60)  // 10 + 20 + 30
    XCTAssertEqual(rolled[2], 20)
    XCTAssertEqual(rolled[3], 30)
  }

  func testRolledUpElapsedWithNoOwnTime() {
    let nodes = [
      TimerNode(id: 1, parentId: nil),
      TimerNode(id: 2, parentId: 1),
    ]
    let elapsed: [Int: TimeInterval] = [2: 15]
    let rolled = TimerStore.rolledUpElapsedByTaskId(nodes: nodes, ownElapsed: elapsed)
    XCTAssertEqual(rolled[1], 15)
    XCTAssertEqual(rolled[2], 15)
  }
}

/// A cycle in the parent chain makes a task its own descendant. The data should
/// never contain one, but it arrives over the network — and the roll-up used to
/// recurse into it forever, taking the process down with it.
final class TimerStoreCycleTests: XCTestCase {

  func testACycleInTheParentChainDoesNotRecurseForever() {
    let nodes = [
      TimerNode(id: 1, parentId: 2),
      TimerNode(id: 2, parentId: 1),
    ]

    let rolled = TimerStore.rolledUpElapsedByTaskId(
      nodes: nodes, ownElapsed: [1: 10, 2: 5])

    // Reaching this line at all is most of the point. A cycle has no
    // well-defined subtree, so what each entry sums depends on which node the
    // walk started from; what must hold is that it terminates and counts each
    // task's own time at most once.
    XCTAssertEqual(rolled[1], 15, "the first node walked sums the cycle once")
    XCTAssertEqual(rolled[2], 5, "and does not double back through its ancestor")
  }

  func testALongerCycleAlsoTerminates() {
    let nodes = [
      TimerNode(id: 1, parentId: 3),
      TimerNode(id: 2, parentId: 1),
      TimerNode(id: 3, parentId: 2),
    ]

    let rolled = TimerStore.rolledUpElapsedByTaskId(
      nodes: nodes, ownElapsed: [1: 1, 2: 2, 3: 4])

    XCTAssertEqual(rolled[1], 7)
  }

  /// A task pointing at itself is the degenerate case of the same shape.
  func testASelfParentedTaskTerminates() {
    let rolled = TimerStore.rolledUpElapsedByTaskId(
      nodes: [TimerNode(id: 1, parentId: 1)], ownElapsed: [1: 3])

    XCTAssertEqual(rolled[1], 3)
  }

  /// The ordinary case still rolls a subtree up into its root.
  func testAnAcyclicTreeStillRollsUp() {
    let nodes = [
      TimerNode(id: 1, parentId: nil),
      TimerNode(id: 2, parentId: 1),
      TimerNode(id: 3, parentId: 2),
    ]

    let rolled = TimerStore.rolledUpElapsedByTaskId(
      nodes: nodes, ownElapsed: [1: 1, 2: 2, 3: 4])

    XCTAssertEqual(rolled[1], 7)
    XCTAssertEqual(rolled[2], 6)
    XCTAssertEqual(rolled[3], 4)
  }
}
