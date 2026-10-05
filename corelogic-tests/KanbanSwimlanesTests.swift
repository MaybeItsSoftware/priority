import XCTest

@testable import TaktCore

/// A single row of columns says what state a task is in but never what it is
/// for. For a tree that is a handful of goals and a couple of hundred
/// descendants, the goal is the thing carrying the meaning.
final class KanbanSwimlanesTests: XCTestCase {

  private struct Node: VisibilityTask {
    var id: Int
    var content: String = ""
    var position: Int?
    var parentId: Int?
    var due: String?
    var dueDate: Date? { nil }
    var status: Int = 0
  }

  //  1 "Comp Sci" ── 2 ── 4
  //  5 "Summer"    ── 6
  //  9 a top-level task with no children
  private let tree = [
    Node(id: 1, content: "Comp Sci", position: 1, parentId: 0),
    Node(id: 2, content: "COMP0017", position: 1, parentId: 1),
    Node(id: 4, content: "past papers", position: 1, parentId: 2),
    Node(id: 5, content: "Summer", position: 2, parentId: 0),
    Node(id: 6, content: "learn drums", position: 1, parentId: 5),
    Node(id: 9, content: "loose end", position: 3, parentId: 0),
  ]

  private var byId: [Int: Node] {
    Dictionary(uniqueKeysWithValues: tree.map { ($0.id, $0) })
  }

  private func ancestor(_ id: Int) -> Int? {
    KanbanSwimlanes.topLevelAncestor(of: byId[id]!, taskById: byId)?.id
  }

  // MARK: - Finding the goal

  /// Depth is the point: a grandchild belongs to the goal, not to its parent.
  func testAGrandchildResolvesToItsTopLevelGoal() {
    XCTAssertEqual(ancestor(4), 1)
    XCTAssertEqual(ancestor(2), 1)
    XCTAssertEqual(ancestor(6), 5)
  }

  func testATopLevelTaskHasNoAncestor() {
    XCTAssertNil(ancestor(1))
    XCTAssertNil(ancestor(9))
  }

  /// This runs during a cache rebuild on the main actor, so an unguarded walk
  /// freezes the app rather than merely drawing the wrong row.
  func testACycleTerminatesRatherThanSpinning() {
    let cyclic = [Node(id: 1, parentId: 2), Node(id: 2, parentId: 1)]
    let map = Dictionary(uniqueKeysWithValues: cyclic.map { ($0.id, $0) })
    _ = KanbanSwimlanes.topLevelAncestor(of: cyclic[0], taskById: map)
  }

  func testAMissingParentStopsTheWalkRatherThanFailing() {
    let orphan = Node(id: 7, parentId: 999)
    XCTAssertNil(KanbanSwimlanes.topLevelAncestor(of: orphan, taskById: byId))
  }

  // MARK: - Building the rows

  func testEachGoalBecomesALaneTitledAfterIt() {
    let lanes = KanbanSwimlanes.lanes(for: tree, taskById: byId)
    XCTAssertEqual(lanes.first(where: { $0.id == 1 })?.title, "Comp Sci")
    XCTAssertEqual(lanes.first(where: { $0.id == 5 })?.title, "Summer")
  }

  func testDescendantsLandInTheirGoalsLane() {
    let lanes = KanbanSwimlanes.lanes(for: tree, taskById: byId)
    let compSci = lanes.first { $0.id == 1 }
    XCTAssertEqual(compSci?.tasks.map(\.id).sorted(), [2, 4])
  }

  /// The goals themselves have no ancestor, so they gather in the fallback lane
  /// rather than vanishing from a board grouped by goal.
  func testTopLevelTasksGatherInTheUnassignedLane() {
    let lanes = KanbanSwimlanes.lanes(for: tree, taskById: byId, unassignedTitle: "No goal")
    let unassigned = lanes.first { $0.id == 0 }
    XCTAssertEqual(unassigned?.title, "No goal")
    XCTAssertEqual(unassigned?.tasks.map(\.id).sorted(), [1, 5, 9])
  }

  /// An empty lane is a whole row of empty columns — a lot of screen for
  /// "nothing here".
  func testLanesWithNoTasksAreDropped() {
    let lanes = KanbanSwimlanes.lanes(for: [byId[4]!], taskById: byId)
    XCTAssertEqual(lanes.count, 1)
    XCTAssertEqual(lanes[0].id, 1)
  }

  func testAnExplicitOrderLeadsAndTheRestFollow() {
    let lanes = KanbanSwimlanes.lanes(for: tree, taskById: byId, laneOrder: [5, 1])
    XCTAssertEqual(Array(lanes.prefix(2)).map(\.id), [5, 1])
  }

  func testAnOrderNamingAnAbsentLaneIsIgnored() {
    let lanes = KanbanSwimlanes.lanes(for: tree, taskById: byId, laneOrder: [999, 5])
    XCTAssertEqual(lanes.first?.id, 5)
  }

  func testNoTasksMeansNoLanes() {
    XCTAssertTrue(KanbanSwimlanes.lanes(for: [Node](), taskById: byId).isEmpty)
  }
}
