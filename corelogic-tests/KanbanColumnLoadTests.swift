import XCTest

@testable import TaktCore

/// A WIP limit is advisory. Going over is shown, never prevented — a board that
/// refuses a drop because a number says so is a board people stop using.
final class KanbanColumnLoadTests: XCTestCase {

  private func column(limit: Int?) -> KanbanColumn {
    KanbanColumn(name: "Doing", conditions: [.catchAll], wipLimit: limit)
  }

  func testNoLimitIsAlwaysUnlimited() {
    XCTAssertEqual(column(limit: nil).load(count: 500), .unlimited)
  }

  /// A saved zero would otherwise read as "every card is over the limit".
  func testAZeroOrNegativeLimitIsTreatedAsNoLimit() {
    XCTAssertEqual(column(limit: 0).load(count: 3), .unlimited)
    XCTAssertEqual(column(limit: -2).load(count: 3), .unlimited)
  }

  func testTheThreeStatesOfALimitedColumn() {
    XCTAssertEqual(column(limit: 3).load(count: 2), .within)
    XCTAssertEqual(column(limit: 3).load(count: 3), .atLimit)
    XCTAssertEqual(column(limit: 3).load(count: 5), .over(by: 2))
  }

  func testAnEmptyLimitedColumnIsWithinIt() {
    XCTAssertEqual(column(limit: 3).load(count: 0), .within)
  }

  /// Boards saved before limits existed must still decode.
  func testAColumnSavedWithoutALimitDecodesAsUnlimited() throws {
    let legacy = """
      {"id":"\(UUID().uuidString)","name":"Today","conditions":[],"sortOrder":"position"}
      """
    let decoded = try JSONDecoder().decode(
      KanbanColumn.self, from: Data(legacy.utf8))
    XCTAssertNil(decoded.wipLimit)
    XCTAssertEqual(decoded.load(count: 99), .unlimited)
  }
}
