import XCTest

@testable import TaktCore

final class TaskDraftReanchorTests: XCTestCase {
  private func flat(_ ids: String...) -> [TaskDraftRow] { ids.map { TaskDraftRow(id: $0) } }

  func testAnAnchorWhoseTaskIsStillDrawnIsKept() {
    let rows = flat("a", "b", "c")
    XCTAssertEqual(TaskDraftReanchor.anchor(.below("b"), previous: rows, current: flat("b", "c")), .below("b"))
    XCTAssertEqual(TaskDraftReanchor.anchor(.above("b"), previous: rows, current: flat("a", "b")), .above("b"))
  }

  func testTheFootOfThePaneStaysThere() {
    XCTAssertEqual(TaskDraftReanchor.anchor(.end, previous: flat("a"), current: []), .end)
  }

  /// A reference that was not on screen before has no position to keep: a
  /// task just created and made the reference, read in by this very refresh.
  func testAnAnchorThatWasNotDrawnBeforeIsLeftAlone() {
    XCTAssertEqual(TaskDraftReanchor.anchor(.below("new"), previous: flat("a"), current: flat("a")), .below("new"))
  }

  func testBelowAVanishedTaskMovesBelowTheOneBeforeIt() {
    let anchor = TaskDraftReanchor.anchor(.below("b"), previous: flat("a", "b", "c"), current: flat("a", "c"))
    XCTAssertEqual(anchor, .below("a"))
  }

  func testBelowTheFirstTaskMovesAboveTheOneAfterIt() {
    let anchor = TaskDraftReanchor.anchor(.below("a"), previous: flat("a", "b"), current: flat("b"))
    XCTAssertEqual(anchor, .above("b"))
  }

  func testAboveAVanishedTaskStaysInTheSameGap() {
    // The row sat between a and b; a is still there, so it goes below a.
    XCTAssertEqual(
      TaskDraftReanchor.anchor(.above("b"), previous: flat("a", "b", "c"), current: flat("a", "c")), .below("a"))
    // With nothing before the gap it goes above what followed.
    XCTAssertEqual(TaskDraftReanchor.anchor(.above("a"), previous: flat("a", "b"), current: flat("b")), .above("b"))
  }

  /// Neighbours leaving at the same time are skipped over, not taken.
  func testSeveralVanishingTogetherReachTheNearestSurvivor() {
    let anchor = TaskDraftReanchor.anchor(
      .below("c"), previous: flat("a", "b", "c", "d", "e"), current: flat("a", "e"))
    XCTAssertEqual(anchor, .below("a"))
  }

  func testAnEmptiedPaneDraftsAtItsFoot() {
    XCTAssertEqual(TaskDraftReanchor.anchor(.below("a"), previous: flat("a"), current: []), .end)
  }

  /// In the outline the row keeps the level the new task was to be filed at:
  /// a sibling before it rather than a deeper row that happens to be closer.
  func testTheOutlinePrefersASiblingToACloserDeeperRow() {
    let previous = [
      TaskDraftRow(id: "p"),
      TaskDraftRow(id: "a", parentID: "p"),
      TaskDraftRow(id: "a1", parentID: "a"),
      TaskDraftRow(id: "b", parentID: "p"),
      TaskDraftRow(id: "c", parentID: "p"),
    ]
    let current = previous.filter { $0.id != "b" }
    XCTAssertEqual(TaskDraftReanchor.anchor(.below("b"), previous: previous, current: current), .below("a"))
  }

  func testTheOnlyChildGoneDraftsInsideItsParent() {
    let previous = [TaskDraftRow(id: "p"), TaskDraftRow(id: "a", parentID: "p"), TaskDraftRow(id: "q")]
    let current = [TaskDraftRow(id: "p"), TaskDraftRow(id: "q")]
    XCTAssertEqual(TaskDraftReanchor.anchor(.below("a"), previous: previous, current: current), .inside("p"))
  }

  /// Drafting inside a task that goes: its children still drawn keep the new
  /// task under it; with none, it lands beside where the task was.
  func testInsideAVanishedTaskKeepsToItsChildrenThenItsLevel() {
    let previous = [
      TaskDraftRow(id: "a"),
      TaskDraftRow(id: "b"),
      TaskDraftRow(id: "b1", parentID: "b"),
      TaskDraftRow(id: "c"),
    ]
    let withChild = previous.filter { $0.id != "b" }
    XCTAssertEqual(TaskDraftReanchor.anchor(.inside("b"), previous: previous, current: withChild), .above("b1"))
    let withoutChildren = previous.filter { $0.id != "b" && $0.id != "b1" }
    XCTAssertEqual(TaskDraftReanchor.anchor(.inside("b"), previous: previous, current: withoutChildren), .below("a"))
  }

  /// No sibling and no parent left: any row near the gap is better than
  /// losing the row.
  func testWithNoSiblingOrParentAnyNeighbourWillDo() {
    let previous = [TaskDraftRow(id: "x"), TaskDraftRow(id: "a", parentID: "p")]
    let current = [TaskDraftRow(id: "x")]
    XCTAssertEqual(TaskDraftReanchor.anchor(.below("a"), previous: previous, current: current), .below("x"))
  }
}
