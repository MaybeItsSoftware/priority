import XCTest

@testable import TaktCore

final class CursorSteppingTests: XCTestCase {
  func testASingleStepWrapsAroundEitherEnd() {
    XCTAssertEqual(CursorStepping.index(from: 0, by: -1, count: 5), 4)
    XCTAssertEqual(CursorStepping.index(from: 4, by: 1, count: 5), 0)
    XCTAssertEqual(CursorStepping.index(from: 2, by: 1, count: 5), 3)
  }

  func testAPageStopsAtTheEnds() {
    XCTAssertEqual(CursorStepping.index(from: 2, by: -8, count: 5), 0)
    XCTAssertEqual(CursorStepping.index(from: 2, by: 8, count: 5), 4)
  }

  func testOneRowStaysPut() {
    XCTAssertEqual(CursorStepping.index(from: 0, by: 1, count: 1), 0)
    XCTAssertEqual(CursorStepping.index(from: 0, by: -1, count: 1), 0)
  }
}
