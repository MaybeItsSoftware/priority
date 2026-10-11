import XCTest

@testable import TaktCore

final class BlockedSectionTests: XCTestCase {
  func testTheLabelHeadsEachGroupsBlockedTail() {
    // An outline: a's subtasks drawn between it and its blocked siblings.
    let items: [(id: String, group: String)] = [
      ("a", "root"), ("a1", "a"), ("a2", "a"), ("a3", "a"),
      ("b", "root"), ("c", "root"),
    ]
    let labelled = BlockedSection.labelledIDs(items, blocked: ["a2", "a3", "b", "c"])
    XCTAssertEqual(labelled, ["a2", "b"])
  }

  func testNothingBlockedNoLabel() {
    XCTAssertTrue(BlockedSection.labelledIDs([(id: "a", group: 0), (id: "b", group: 0)], blocked: []).isEmpty)
  }

  /// A blocked task with an open one after it is greyed, not labelled: the
  /// label would head a section that is not all blocked.
  func testABlockedTaskAboveAnOpenOneIsNotLabelled() {
    let items: [(id: String, group: Int)] = [(id: "a", group: 0), (id: "b", group: 0), (id: "c", group: 0)]
    XCTAssertTrue(BlockedSection.labelledIDs(items, blocked: ["a"]).isEmpty)
    XCTAssertEqual(BlockedSection.labelledIDs(items, blocked: ["a", "c"]), ["c"])
  }

  func testAGroupOfOnlyBlockedTasksIsLabelledAtItsTop() {
    let items: [(id: String, group: String)] = [("a", "done"), ("b", "waiting"), ("c", "waiting")]
    XCTAssertEqual(BlockedSection.labelledIDs(items, blocked: ["b", "c"]), ["b"])
  }
}
