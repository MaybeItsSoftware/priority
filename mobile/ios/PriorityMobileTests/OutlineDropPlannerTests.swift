import PriorityWorkspace
import XCTest
@testable import Priority

final class OutlineDropPlannerTests: XCTestCase {
  private func row(_ id: String, depth: Int, parent: String?) -> OutlineRow {
    OutlineRow(
      id: id, title: id, depth: depth, status: .open, isList: false, isPromoted: false, parentID: parent,
      listID: "L", dueAt: nil, estimateSeconds: nil, hasNotes: false, hasChildren: false, isFolded: false,
      isPlanned: false, listName: nil)
  }

  func testDroppingBeforeASiblingPlacesItBeforeThatSibling() {
    let rows = [row("a", depth: 0, parent: nil), row("b", depth: 0, parent: nil), row("c", depth: 0, parent: nil)]
    XCTAssertEqual(OutlineDropPlanner.plan(rows: rows, source: 2, destination: 0), .before("a"))
  }

  func testDroppingAfterTheLastSiblingMovesItToTheEnd() {
    let rows = [row("a", depth: 0, parent: nil), row("b", depth: 0, parent: nil), row("c", depth: 0, parent: nil)]
    XCTAssertEqual(OutlineDropPlanner.plan(rows: rows, source: 0, destination: 3), .toEnd)
  }

  func testDroppingAmongAnotherParentsChildrenReparents() {
    let rows = [
      row("a", depth: 0, parent: nil), row("a1", depth: 1, parent: "a"), row("a2", depth: 1, parent: "a"),
      row("b", depth: 0, parent: nil),
    ]
    XCTAssertEqual(OutlineDropPlanner.plan(rows: rows, source: 3, destination: 2), .reparent(parentID: "a", before: "a2"))
  }

  func testDroppingARowOntoItselfDoesNothing() {
    let rows = [row("a", depth: 0, parent: nil), row("b", depth: 0, parent: nil)]
    XCTAssertNil(OutlineDropPlanner.plan(rows: rows, source: 0, destination: 1))
  }
}
