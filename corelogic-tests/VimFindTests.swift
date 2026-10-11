import XCTest

@testable import TaktCore

final class VimFindTests: XCTestCase {
  private let titles = ["Call Sam", "buy milk", "— cancel gym", "Écrire", "2026 plan", "check post"]

  func testForwardFindsTheNextRowBeginningWithTheLetter() {
    XCTAssertEqual(VimFind.index(in: titles, from: 0, character: "c", forward: true), 2)
    XCTAssertEqual(VimFind.index(in: titles, from: 2, character: "C", forward: true), 5)
  }

  func testItWrapsRoundTheEnds() {
    XCTAssertEqual(VimFind.index(in: titles, from: 5, character: "c", forward: true), 0)
    XCTAssertEqual(VimFind.index(in: titles, from: 0, character: "c", forward: false), 5)
  }

  func testBackwardFindsThePreviousRow() {
    XCTAssertEqual(VimFind.index(in: titles, from: 5, character: "c", forward: false), 2)
  }

  func testWithNoCursorTheFirstMatchCounts() {
    XCTAssertEqual(VimFind.index(in: titles, from: nil, character: "c", forward: true), 0)
    XCTAssertEqual(VimFind.index(in: titles, from: nil, character: "c", forward: false), 5)
  }

  func testLeadingPunctuationCaseAndAccentsAreIgnored() {
    XCTAssertEqual(VimFind.index(in: titles, from: 0, character: "e", forward: true), 3)
    XCTAssertEqual(VimFind.index(in: titles, from: 0, character: "2", forward: true), 4)
  }

  func testTheOnlyMatchIsFoundFromItself() {
    XCTAssertEqual(VimFind.index(in: titles, from: 1, character: "b", forward: true), 1)
  }

  func testNothingMatchesNothing() {
    XCTAssertNil(VimFind.index(in: titles, from: 0, character: "z", forward: true))
    XCTAssertNil(VimFind.index(in: titles, from: 0, character: " ", forward: true))
    XCTAssertNil(VimFind.index(in: [], from: nil, character: "a", forward: true))
  }
}
