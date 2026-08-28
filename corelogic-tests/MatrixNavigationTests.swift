import XCTest

@testable import PriorityCore

/// The plot answered only to the mouse. These are the properties that make the
/// arrow keys a real way round it rather than an approximation of one.
final class MatrixNavigationTests: XCTestCase {

  private struct Node: VisibilityTask {
    var id: Int
    var content: String = ""
    var position: Int?
    var parentId: Int?
    var due: String?
    var dueDate: Date? { nil }
    var status: Int = 0
  }

  /// Builds one single-task cluster per coordinate, in the order given.
  private func plot(_ coordinates: [(Int, Double, Double)]) -> [MatrixCluster<Node>] {
    coordinates.map { id, urgency, importance in
      MatrixCluster(
        representative: Node(id: id), taskIds: [id],
        urgency: urgency, importance: importance, isInherited: false)
    }
  }

  private func target(
    from: (urgency: Double, importance: Double)?,
    _ direction: MatrixDirection,
    _ clusters: [MatrixCluster<Node>]
  ) -> Int? {
    MatrixNavigation.target(from: from, direction: direction, in: clusters)?.representative.id
  }

  // MARK: - One step at a time

  func testUpTakesTheNextImportanceAbove() {
    let clusters = plot([(1, 0, 1), (2, 0, 5), (3, 0, 9)])
    XCTAssertEqual(target(from: (0, 1), .up, clusters), 2)
    XCTAssertEqual(target(from: (0, 5), .up, clusters), 3)
  }

  func testDownUpAndLeftRightAreOpposites() {
    let clusters = plot([(1, -5, 0), (2, 0, 0), (3, 5, 0)])
    XCTAssertEqual(target(from: (0, 0), .right, clusters), 3)
    XCTAssertEqual(target(from: (5, 0), .left, clusters), 2)
    XCTAssertEqual(target(from: (-5, 0), .right, clusters), 2)
  }

  /// The step is by level, not by distance, so a dot at the same importance
  /// never blocks the one above it.
  func testMovementIgnoresHowFarApartTheDotsAreDrawn() {
    let clusters = plot([(1, 0, 0), (2, 9, 0), (3, -9, 1)])
    XCTAssertEqual(target(from: (0, 0), .up, clusters), 3)
  }

  func testTheNearestOnTheOtherAxisBreaksATie() {
    let clusters = plot([(1, 0, 0), (2, 8, 4), (3, 1, 4)])
    XCTAssertEqual(target(from: (0, 0), .up, clusters), 3)
  }

  /// Ties on both axes are settled by the plot's own order, so the same press
  /// from the same dot always lands in the same place.
  func testAFullTieKeepsTheEarlierCluster() {
    let clusters = plot([(1, 0, 0), (2, 3, 4), (3, 3, 4)])
    XCTAssertEqual(target(from: (0, 0), .up, clusters), 2)
  }

  // MARK: - Edges

  func testThereIsNoTargetPastTheEdgeOfThePlot() {
    let clusters = plot([(1, 0, 9)])
    XCTAssertNil(target(from: (0, 9), .up, clusters))
  }

  func testALevelIsNotItsOwnTarget() {
    let clusters = plot([(1, 0, 5), (2, 4, 5)])
    XCTAssertNil(target(from: (0, 5), .up, clusters))
  }

  func testAnEmptyPlotHasNowhereToGo() {
    XCTAssertNil(target(from: (0, 0), .up, []))
    XCTAssertNil(target(from: nil, .up, []))
  }

  // MARK: - Joining the plot

  /// A selection with no coordinate — an unplaced task, or nothing selected at
  /// all — must still be able to get onto the plot, or the keyboard can only
  /// leave it.
  func testAnArrowFromNowhereEntersAtTheDotNearestTheMiddle() {
    let clusters = plot([(1, 8, 8), (2, 1, -1), (3, -5, 5)])
    for direction in MatrixDirection.allCases {
      XCTAssertEqual(target(from: nil, direction, clusters), 2)
    }
  }

  // MARK: - Triage order

  private func nextUnplaced(after id: Int, _ unplaced: [Int], _ order: [Int]) -> Int? {
    MatrixNavigation.nextUnplaced(
      after: id, unplaced: unplaced.map { Node(id: $0) }, order: order
    )?.id
  }

  func testTriageGoesForwardFromTheTaskJustPlaced() {
    XCTAssertEqual(nextUnplaced(after: 2, [1, 3, 4], [1, 2, 3, 4]), 3)
  }

  /// Placements land tasks anywhere in the order, so a pass that only ever
  /// searched forward would report itself finished with the drawer still full.
  func testTriageWrapsRatherThanStrandingWhatIsAboveTheCursor() {
    XCTAssertEqual(nextUnplaced(after: 4, [1, 2], [1, 2, 3, 4]), 1)
  }

  /// The task just placed is no longer unplaced, so its position has to come
  /// from the full order rather than from the unplaced list.
  func testTheJustPlacedTaskNeedNotBeInTheUnplacedList() {
    XCTAssertEqual(nextUnplaced(after: 3, [4], [1, 2, 3, 4]), 4)
  }

  func testNothingLeftToTriageIsNoMove() {
    XCTAssertNil(nextUnplaced(after: 1, [], [1, 2]))
  }

  func testATaskMissingFromTheOrderStartsAtTheTop() {
    XCTAssertEqual(nextUnplaced(after: 99, [2, 3], [1, 2, 3]), 2)
  }

  // MARK: - Opening a pile

  func testAPileIsFoundByAnyOfItsMembers() {
    let clusters = [
      MatrixCluster(
        representative: Node(id: 1), taskIds: [1, 7, 9],
        urgency: 6, importance: 6, isInherited: false),
      MatrixCluster(
        representative: Node(id: 2), taskIds: [2],
        urgency: -2, importance: 6, isInherited: false),
    ]
    for member in [1, 7, 9] {
      XCTAssertEqual(
        MatrixNavigation.pile(containing: member, in: clusters)?.representative.id, 1)
    }
    XCTAssertNil(MatrixNavigation.pile(containing: 99, in: clusters))
  }

  /// An open pile is remembered as its point, so tasks arriving in it or
  /// leaving it do not close it.
  func testAPileSurvivesItsMembershipChanging() {
    let key = MatrixPileKey(urgency: 6, importance: 6)
    let before = plot([(1, 6, 6)])
    let after = [
      MatrixCluster(
        representative: Node(id: 1), taskIds: [1, 4, 5],
        urgency: 6, importance: 6, isInherited: false)
    ]
    XCTAssertEqual(MatrixNavigation.pile(at: key, in: before)?.count, 1)
    XCTAssertEqual(MatrixNavigation.pile(at: key, in: after)?.count, 3)
  }

  /// The goal moved, so there is nothing at that point any more — the drawer
  /// has to close rather than list tasks that are now somewhere else.
  func testAPileWhoseGoalMovedIsGone() {
    let key = MatrixPileKey(urgency: 6, importance: 6)
    XCTAssertNil(MatrixNavigation.pile(at: key, in: plot([(1, 5, 5)])))
    XCTAssertNil(MatrixNavigation.pile(at: key, in: plot([])))
  }

  // MARK: - Stepping inside an open pile

  func testStepsRunThroughThePileInOrder() {
    XCTAssertEqual(MatrixNavigation.member(from: 1, by: 1, in: [1, 2, 3]), 2)
    XCTAssertEqual(MatrixNavigation.member(from: 3, by: -1, in: [1, 2, 3]), 2)
  }

  /// The ends stop rather than wrap: a pile is a list being read, and running
  /// off it should be a dead end, not a loop.
  func testTheEndsOfAPileAreDeadEnds() {
    XCTAssertNil(MatrixNavigation.member(from: 3, by: 1, in: [1, 2, 3]))
    XCTAssertNil(MatrixNavigation.member(from: 1, by: -1, in: [1, 2, 3]))
  }

  func testAStepFromOutsideThePileEntersAtTheNearEnd() {
    XCTAssertEqual(MatrixNavigation.member(from: 99, by: 1, in: [1, 2, 3]), 1)
    XCTAssertEqual(MatrixNavigation.member(from: 99, by: -1, in: [1, 2, 3]), 3)
    XCTAssertEqual(MatrixNavigation.member(from: nil, by: 1, in: [1, 2, 3]), 1)
  }

  func testAnEmptyPileHasNoMembersToStepTo() {
    XCTAssertNil(MatrixNavigation.member(from: nil, by: 1, in: []))
  }

  /// Every dot has to be reachable: walking up from the bottom must visit each
  /// distinct importance rather than stalling on one.
  func testRepeatedPressesWalkEveryLevel() {
    let clusters = plot([(1, 0, -9), (2, 3, -2), (3, -7, 0), (4, 1, 4), (5, 2, 9)])
    var visited: [Int] = []
    var coordinate: (urgency: Double, importance: Double)? = (0, -9)
    while let next = MatrixNavigation.target(
      from: coordinate, direction: .up, in: clusters)
    {
      visited.append(next.representative.id)
      coordinate = (next.urgency, next.importance)
    }
    XCTAssertEqual(visited, [2, 3, 4, 5])
  }
}
