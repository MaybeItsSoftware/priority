import XCTest

@testable import TaktCore

/// Inheritance shares a coordinate exactly, so a pile is the normal case rather
/// than a coincidence. These are the properties the plot relies on to draw one
/// dot for it.
final class MatrixClusteringTests: XCTestCase {

  private struct Node: VisibilityTask {
    var id: Int
    var content: String = ""
    var position: Int?
    var parentId: Int?
    var due: String?
    var dueDate: Date? { nil }
    var status: Int = 0
  }

  private func own(_ urgency: Double, _ importance: Double) -> EffectiveEisenhowerLevel {
    EffectiveEisenhowerLevel(
      urgency: urgency, importance: importance, isInherited: false, sourceTaskId: nil)
  }

  private func inherited(
    _ urgency: Double, _ importance: Double, from sourceTaskId: Int
  ) -> EffectiveEisenhowerLevel {
    EffectiveEisenhowerLevel(
      urgency: urgency, importance: importance, isInherited: true, sourceTaskId: sourceTaskId)
  }

  func testTasksSharingACoordinateBecomeOneCluster() {
    let tasks = [Node(id: 1), Node(id: 2), Node(id: 3)]
    let clusters = MatrixClustering.clusters(
      for: tasks,
      levels: [1: own(5, 5), 2: inherited(5, 5, from: 1), 3: inherited(5, 5, from: 1)]
    )

    XCTAssertEqual(clusters.count, 1)
    XCTAssertEqual(clusters[0].count, 3)
    XCTAssertEqual(clusters[0].taskIds, [1, 2, 3])
    XCTAssertEqual(clusters[0].urgency, 5)
    XCTAssertEqual(clusters[0].importance, 5)
  }

  func testDistinctCoordinatesStayDistinct() {
    let tasks = [Node(id: 1), Node(id: 2)]
    let clusters = MatrixClustering.clusters(for: tasks, levels: [1: own(5, 5), 2: own(-5, 5)])

    XCTAssertEqual(clusters.count, 2)
    XCTAssertEqual(clusters.map(\.count), [1, 1])
  }

  /// The point of the representative: dragging the cluster has to move the
  /// coordinate the rest of the pile is following, not one of the followers.
  func testTheOwnerRepresentsThePileEvenWhenItIsNotListedFirst() {
    let tasks = [Node(id: 2), Node(id: 3), Node(id: 1)]
    let clusters = MatrixClustering.clusters(
      for: tasks,
      levels: [1: own(5, 5), 2: inherited(5, 5, from: 1), 3: inherited(5, 5, from: 1)]
    )

    XCTAssertEqual(clusters.count, 1)
    XCTAssertEqual(clusters[0].representative.id, 1)
    XCTAssertFalse(clusters[0].isInherited)
  }

  /// A scope that excludes the goal itself: every task here is borrowing the
  /// coordinate, and the cluster has to say so — it draws hollow.
  func testAPileWithNoOwnerIsInherited() {
    let tasks = [Node(id: 2), Node(id: 3)]
    let clusters = MatrixClustering.clusters(
      for: tasks,
      levels: [2: inherited(5, 5, from: 1), 3: inherited(5, 5, from: 1)]
    )

    XCTAssertEqual(clusters.count, 1)
    XCTAssertTrue(clusters[0].isInherited)
    XCTAssertEqual(clusters[0].representative.id, 2)
  }

  func testUnplacedTasksAreNotClustered() {
    let tasks = [Node(id: 1), Node(id: 2)]
    let clusters = MatrixClustering.clusters(for: tasks, levels: [1: own(5, 5)])

    XCTAssertEqual(clusters.count, 1)
    XCTAssertEqual(clusters[0].taskIds, [1])
  }

  /// Order is by first appearance so an unrelated edit elsewhere in the list
  /// cannot reshuffle the plot.
  func testClusterOrderFollowsFirstAppearance() {
    let tasks = [Node(id: 7), Node(id: 1), Node(id: 8)]
    let clusters = MatrixClustering.clusters(
      for: tasks,
      levels: [7: own(-5, -5), 1: own(5, 5), 8: inherited(-5, -5, from: 7)]
    )

    XCTAssertEqual(clusters.map(\.representative.id), [7, 1])
    XCTAssertEqual(clusters[0].taskIds, [7, 8])
  }

  func testASingleTaskKeepsThePlainDotSize() {
    XCTAssertEqual(MatrixClustering.dotDiameter(count: 1), 6)
    XCTAssertEqual(MatrixClustering.dotDiameter(count: 0), 6)
  }

  func testDotAreaTracksTheCountUpToACap() {
    XCTAssertEqual(MatrixClustering.dotDiameter(count: 4), 12, accuracy: 0.001)
    XCTAssertEqual(MatrixClustering.dotDiameter(count: 9), 18, accuracy: 0.001)
    XCTAssertEqual(MatrixClustering.dotDiameter(count: 200), 18, accuracy: 0.001)
  }

  /// A 6pt dot is a small target, so the catchment has to be bigger than the
  /// dot — but bounded, which is the whole point: an unbounded nearest-dot
  /// search names something no matter where the pointer is.
  func testTheCatchmentIsWiderThanTheDotItCovers() {
    for count in [1, 4, 44] {
      let radius = MatrixClustering.hitRadius(count: count)
      XCTAssertGreaterThan(radius, MatrixClustering.dotDiameter(count: count) / 2)
    }
  }

  func testTheCatchmentGrowsWithThePile() {
    XCTAssertLessThan(
      MatrixClustering.hitRadius(count: 1), MatrixClustering.hitRadius(count: 44))
  }
}
