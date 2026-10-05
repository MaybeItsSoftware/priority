import XCTest

@testable import TaktCore

final class DayArrangementTests: XCTestCase {
  private let order = ["a", "b", "c", "d"]

  func testMovingDownSwapsWithTheNextTask() {
    XCTAssertEqual(DayArrangement.moving("b", by: 1, in: order), ["a", "c", "b", "d"])
  }

  func testMovingUpSwapsWithThePreviousTask() {
    XCTAssertEqual(DayArrangement.moving("c", by: -1, in: order), ["a", "c", "b", "d"])
  }

  func testAMoveBeyondTheEndStopsAtIt() {
    XCTAssertEqual(DayArrangement.moving("b", by: 10, in: order), ["a", "c", "d", "b"])
  }

  /// Nothing to write: the task is already at the top, or not planned at all.
  func testNoMoveIsNil() {
    XCTAssertNil(DayArrangement.moving("a", by: -1, in: order))
    XCTAssertNil(DayArrangement.moving("d", by: 1, in: order))
    XCTAssertNil(DayArrangement.moving("z", by: 1, in: order))
    XCTAssertNil(DayArrangement.moving("b", by: 0, in: order))
  }

  func testApplyingReordersOnlyThePlannedEntries() {
    let plan = [
      DayPlanEntry(id: "run", reason: .running),
      DayPlanEntry(id: "a", reason: .planned),
      DayPlanEntry(id: "b", reason: .planned),
      DayPlanEntry(id: "late", reason: .overdue),
    ]
    XCTAssertEqual(
      DayArrangement.applying(["b", "a"], to: plan).map(\.id), ["run", "b", "a", "late"])
    XCTAssertEqual(
      DayArrangement.applying(["b", "a"], to: plan).map(\.reason),
      [.running, .planned, .planned, .overdue])
  }
}
