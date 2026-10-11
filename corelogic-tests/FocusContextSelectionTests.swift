import TaktCore
import XCTest

final class FocusContextSelectionTests: XCTestCase {
  private let places: Set<String> = ["home", "campus"]

  func testTurningOnAPlaceReplacesTheLastPlace() {
    let next = FocusContextSelection.toggling("campus", isLocation: true, in: ["home", "floor"], locationIDs: places)
    XCTAssertEqual(next, ["campus", "floor"])
  }

  func testCapabilitiesCombine() {
    let next = FocusContextSelection.toggling("quiet", isLocation: false, in: ["home", "floor"], locationIDs: places)
    XCTAssertEqual(next, ["home", "floor", "quiet"])
  }

  func testTogglingAnActiveConditionTurnsOnlyItOff() {
    XCTAssertEqual(
      FocusContextSelection.toggling("home", isLocation: true, in: ["home", "floor"], locationIDs: places),
      ["floor"])
    XCTAssertEqual(
      FocusContextSelection.toggling("floor", isLocation: false, in: ["home", "floor"], locationIDs: places),
      ["home"])
  }

  func testRestoringDropsConditionsThatNoLongerExist() {
    XCTAssertEqual(FocusContextSelection.restoring(["home", "gone"], known: ["home", "floor"]), ["home"])
    XCTAssertEqual(FocusContextSelection.restoring([], known: ["home"]), [])
  }

  func testSummaryFollowsTheConditionsOrder() {
    let names = [(id: "home", name: "Home"), (id: "floor", name: "Floor space"), (id: "quiet", name: "Quiet")]
    XCTAssertEqual(FocusContextSelection.summary(["quiet", "home"], names: names), "Home · Quiet")
    XCTAssertNil(FocusContextSelection.summary([], names: names))
    XCTAssertNil(FocusContextSelection.summary(["gone"], names: names))
  }
}
