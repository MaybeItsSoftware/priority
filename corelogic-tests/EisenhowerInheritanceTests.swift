import XCTest

@testable import TaktCore

/// The reason placing tasks is affordable at all: a tree of a few goals and a
/// couple of hundred descendants needs as many placements as it has goals, not
/// as many as it has tasks.
final class EisenhowerInheritanceTests: XCTestCase {

  private struct Node: VisibilityTask {
    var id: Int
    var content: String = ""
    var position: Int?
    var parentId: Int?
    var due: String?
    var dueDate: Date? { nil }
    var status: Int = 0
  }

  //  1 ── 2 ── 3
  //  9 (unrelated root)
  private let tree = [
    Node(id: 1, content: "goal", position: 1, parentId: 0),
    Node(id: 2, content: "project", position: 1, parentId: 1),
    Node(id: 3, content: "task", position: 1, parentId: 2),
    Node(id: 9, content: "elsewhere", position: 2, parentId: 0),
  ]

  private var byId: [Int: Node] {
    Dictionary(uniqueKeysWithValues: tree.map { ($0.id, $0) })
  }

  private func level(
    _ id: Int, own: [Int: (urgency: Double, importance: Double)]
  ) -> EffectiveEisenhowerLevel? {
    EisenhowerInheritance.effectiveLevel(
      for: byId[id]!, taskById: byId, ownLevel: { own[$0] })
  }

  func testATaskUsesItsOwnCoordinateWhenItHasOne() {
    let resolved = level(3, own: [1: (9, 9), 3: (2, -2)])
    XCTAssertEqual(resolved?.urgency, 2)
    XCTAssertEqual(resolved?.importance, -2)
    XCTAssertEqual(resolved?.isInherited, false)
    XCTAssertEqual(resolved?.sourceTaskId, 3)
  }

  /// The leverage: place the goal, and the whole subtree is classified.
  func testAGrandchildInheritsFromTheGoal() {
    let resolved = level(3, own: [1: (5, 5)])
    XCTAssertEqual(resolved?.urgency, 5)
    XCTAssertEqual(resolved?.isInherited, true)
    XCTAssertEqual(resolved?.sourceTaskId, 1)
  }

  /// Nearest wins, so refining a mid-level project overrides the goal for
  /// everything under it without touching the goal.
  func testTheNearestPlacedAncestorWins() {
    let resolved = level(3, own: [1: (9, 9), 2: (-4, 4)])
    XCTAssertEqual(resolved?.urgency, -4)
    XCTAssertEqual(resolved?.sourceTaskId, 2)
  }

  func testNothingPlacedAnywhereMeansNoCoordinate() {
    XCTAssertNil(level(3, own: [:]))
    XCTAssertNil(level(3, own: [9: (5, 5)]), "a sibling branch must not leak across")
  }

  /// `(0, 0)` is the unset sentinel, so an ancestor sitting on it is not placed
  /// and the walk continues past it.
  func testTheOriginIsNotAPlacementAndIsWalkedThrough() {
    XCTAssertNil(level(3, own: [2: (0, 0)]))
    let resolved = level(3, own: [1: (5, 5), 2: (0, 0)])
    XCTAssertEqual(resolved?.sourceTaskId, 1, "an unset parent must not shadow a placed goal")
  }

  /// Runs during rendering on the main actor; an unguarded walk freezes the app.
  func testACycleTerminates() {
    let cyclic = [Node(id: 1, parentId: 2), Node(id: 2, parentId: 1)]
    let map = Dictionary(uniqueKeysWithValues: cyclic.map { ($0.id, $0) })
    XCTAssertNil(
      EisenhowerInheritance.effectiveLevel(
        for: cyclic[0], taskById: map, ownLevel: { _ in nil }))
  }

  /// A parent id that names nothing — the shape a half-applied reparent leaves
  /// behind — ends the walk instead of ranging over the rest of the tree.
  func testAParentThatNamesNothingEndsTheWalk() {
    let orphan = Node(id: 7, parentId: 999)
    let own: [Int: (urgency: Double, importance: Double)] = [1: (5, 5)]
    XCTAssertNil(
      EisenhowerInheritance.effectiveLevel(
        for: orphan, taskById: byId, ownLevel: { own[$0] }),
      "an unreachable ancestor must not fall through to some other branch")
  }

  // MARK: - Bulk

  func testResolvingAWholeListAgreesWithTheSingleTaskForm() {
    let own: [Int: (urgency: Double, importance: Double)] = [1: (5, 5), 3: (-1, -1)]
    let bulk = EisenhowerInheritance.effectiveLevels(
      for: tree, taskById: byId, ownLevel: { own[$0] })
    XCTAssertEqual(bulk[1]?.isInherited, false)
    XCTAssertEqual(bulk[2]?.isInherited, true)
    XCTAssertEqual(bulk[2]?.sourceTaskId, 1)
    XCTAssertEqual(bulk[3]?.isInherited, false)
    XCTAssertNil(bulk[9], "an unplaced root inherits nothing")
  }
}
