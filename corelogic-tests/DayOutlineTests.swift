import XCTest

@testable import TaktCore

final class DayOutlineTests: XCTestCase {
  /// The workspace:
  ///
  ///     a
  ///       a1
  ///         a1x
  ///       a2
  ///     b
  ///     c
  private let tree: [String: [String]] = ["a": ["a1", "a2"], "a1": ["a1x"]]

  private func rows(day: [String], unfolded: Set<String> = []) -> [DayOutlineRow] {
    DayOutline.rows(day: day, unfolded: unfolded, children: { self.tree[$0] ?? [] })
  }

  private func ids(_ rows: [DayOutlineRow]) -> [String] { rows.map(\.id) }

  func testFoldedTheDayIsFlatAndSaysWhichRowsHaveSubtasks() {
    let day = rows(day: ["a", "b"])
    XCTAssertEqual(ids(day), ["a", "b"])
    XCTAssertEqual(day.map(\.depth), [0, 0])
    XCTAssertEqual(day.map(\.hasChildren), [true, false])
    XCTAssertEqual(day.map(\.isUnfolded), [false, false])
  }

  func testUnfoldingShowsTheOpenSubtasksOneStepIn() {
    let day = rows(day: ["a", "b"], unfolded: ["a"])
    XCTAssertEqual(ids(day), ["a", "a1", "a2", "b"])
    XCTAssertEqual(day.map(\.depth), [0, 1, 1, 0])
    XCTAssertEqual(day.map(\.parentID), [nil, "a", "a", nil])
    XCTAssertTrue(day[0].isUnfolded)
    // a1 has a subtask of its own, still folded.
    XCTAssertTrue(day[1].hasChildren)
    XCTAssertFalse(day[1].isUnfolded)
  }

  func testUnfoldingAChildGoesAStepFurther() {
    let day = rows(day: ["a"], unfolded: ["a", "a1"])
    XCTAssertEqual(ids(day), ["a", "a1", "a1x", "a2"])
    XCTAssertEqual(day.map(\.depth), [0, 1, 2, 1])
  }

  func testAChildsFoldIsKeptWhileItsParentIsFolded() {
    // a1 is still unfolded underneath, but a is shut, so none of it shows.
    XCTAssertEqual(ids(rows(day: ["a", "b"], unfolded: ["a1"])), ["a", "b"])
  }

  func testFoldingHidesTheBranchAgain() {
    XCTAssertEqual(ids(rows(day: ["a", "b"], unfolded: [])), ["a", "b"])
  }

  func testAChildAlsoOnTodayIsDrawnOnceBeneathItsParent() {
    // a2 is on today in its own right, and comes before its parent.
    let open = rows(day: ["a2", "b", "a"], unfolded: ["a"])
    XCTAssertEqual(ids(open), ["b", "a", "a1", "a2"])
    XCTAssertEqual(open.last?.parentID, "a")

    // With the parent folded it keeps its own place in the day.
    XCTAssertEqual(ids(rows(day: ["a2", "b", "a"])), ["a2", "b", "a"])
  }

  func testAGrandchildOnTodayIsDrawnOnceWhereverItsBranchOpens() {
    XCTAssertEqual(ids(rows(day: ["a1x", "a"], unfolded: ["a", "a1"])), ["a", "a1", "a1x", "a2"])
    // a1 folded: the grandchild stays at the top of the day.
    XCTAssertEqual(ids(rows(day: ["a1x", "a"], unfolded: ["a"])), ["a1x", "a", "a1", "a2"])
  }

  func testRightUnfoldsThenStepsIn() {
    let folded = rows(day: ["a", "b"])
    XCTAssertEqual(DayOutline.right(from: "a", in: folded), .unfold("a"))
    let open = rows(day: ["a", "b"], unfolded: ["a"])
    XCTAssertEqual(DayOutline.right(from: "a", in: open), .select("a1"))
    XCTAssertEqual(DayOutline.right(from: "b", in: open), .leave)
    XCTAssertEqual(DayOutline.right(from: "a2", in: open), .leave)
  }

  func testLeftFoldsThenStepsOutThenLeaves() {
    let open = rows(day: ["a", "b"], unfolded: ["a"])
    XCTAssertEqual(DayOutline.left(from: "a2", in: open), .select("a"))
    XCTAssertEqual(DayOutline.left(from: "a", in: open), .fold("a"))
    XCTAssertEqual(DayOutline.left(from: "b", in: open), .leave)
  }

  func testIsDrawnBeneath() {
    let open = rows(day: ["a", "b"], unfolded: ["a", "a1"])
    XCTAssertTrue(DayOutline.isDrawn("a1x", beneath: "a", in: open))
    XCTAssertFalse(DayOutline.isDrawn("b", beneath: "a", in: open))
  }

  func testTickingOffAChildKeepsTheCursorAmongItsSiblings() {
    let before = rows(day: ["a", "b"], unfolded: ["a"])
    // a1 done: a2 takes its place rather than the cursor going to the top.
    XCTAssertEqual(DayOutline.successor(of: "a1", previous: before, remaining: ["a", "a2", "b"]), "a2")
    // The last child done: the one before it.
    XCTAssertEqual(DayOutline.successor(of: "a2", previous: before, remaining: ["a", "a1", "b"]), "a1")
    // An only child done: its parent.
    let only = DayOutline.rows(day: ["a", "b"], unfolded: ["a"], children: { $0 == "a" ? ["a1"] : [] })
    XCTAssertEqual(DayOutline.successor(of: "a1", previous: only, remaining: ["a", "b"]), "a")
    // Still drawn: nothing to do.
    XCTAssertNil(DayOutline.successor(of: "a1", previous: before, remaining: ["a", "a1", "a2", "b"]))
  }
}
