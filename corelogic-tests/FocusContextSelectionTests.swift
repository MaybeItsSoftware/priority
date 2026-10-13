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

  func testAPlaceSaidOnAnEarlierDayIsStale() {
    let london = TimeZone(identifier: "Europe/London")!
    // 2024-01-01 23:00 in London, then 01:00 the next morning.
    let evening = Date(timeIntervalSince1970: 1_704_150_000)
    let night = evening.addingTimeInterval(2 * 3600)
    XCTAssertFalse(FocusContextSelection.isStale(["home"], setAt: evening, now: evening.addingTimeInterval(60), timeZone: london))
    XCTAssertTrue(FocusContextSelection.isStale(["home"], setAt: evening, now: night, timeZone: london))
    XCTAssertFalse(FocusContextSelection.isStale([], setAt: evening, now: night, timeZone: london))
    XCTAssertFalse(FocusContextSelection.isStale(["home"], setAt: nil, now: night, timeZone: london))
  }

  func testChangingTurnsOnePlaceOnAndOthersOff() {
    XCTAssertEqual(
      FocusContextSelection.changing(["home", "floor"], on: ["campus"], off: ["floor"], locationIDs: places),
      ["campus"])
    XCTAssertEqual(FocusContextSelection.changing(["home"], on: ["quiet"], locationIDs: places), ["home", "quiet"])
  }

  func testWaitingCountsEachTaskOncePerCondition() {
    let counts = FocusContextSelection.waitingCounts([
      [["campus", "library"], ["campus"]],
      [["campus"]],
    ])
    XCTAssertEqual(counts, ["campus": 2, "library": 1])
  }
}
