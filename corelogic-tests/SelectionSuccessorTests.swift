import XCTest

@testable import TaktCore

final class SelectionSuccessorTests: XCTestCase {
  /// a
  ///   a1
  ///   a2
  ///   a3
  /// b
  private let parents: [String: String] = ["a1": "a", "a2": "a", "a3": "a"]
  private let order = ["a", "a1", "a2", "a3", "b"]

  private func successor(of id: String, removing gone: Set<String>? = nil) -> String? {
    let remaining = Set(order).subtracting(gone ?? [id])
    return SelectionSuccessor.successor(
      of: id, previousOrder: order, remaining: remaining, parentOf: { self.parents[$0] })
  }

  func testTheNextSiblingTakesTheRowsPlace() {
    XCTAssertEqual(successor(of: "a2"), "a3")
    XCTAssertEqual(successor(of: "a"), "b")
  }

  func testTheLastSiblingFallsBackToTheOneBeforeIt() {
    XCTAssertEqual(successor(of: "a3"), "a2")
    XCTAssertEqual(successor(of: "b"), "a")
  }

  func testAnOnlyChildFallsBackToItsParent() {
    XCTAssertEqual(successor(of: "a2", removing: ["a1", "a2", "a3"]), "a")
  }

  func testWithNoFamilyLeftItTakesTheNeighbourOnScreen() {
    XCTAssertEqual(successor(of: "a2", removing: ["a", "a1", "a2", "a3"]), "b")
  }

  func testARowStillOnScreenOrNeverDrawnHasNoSuccessor() {
    XCTAssertNil(successor(of: "a2", removing: []))
    XCTAssertNil(successor(of: "z"))
    XCTAssertNil(SelectionSuccessor.successor(of: "a", previousOrder: ["a"], remaining: [], parentOf: { _ in nil }))
  }
}
