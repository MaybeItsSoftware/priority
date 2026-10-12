import TaktCore
import XCTest

final class TaskRequirementToggleTests: XCTestCase {
  func testTickingAConditionAddsAGroupOfItsOwn() {
    XCTAssertEqual(TaskRequirementToggle.toggling("floor", in: nil, places: []), [["floor"]])
    XCTAssertEqual(TaskRequirementToggle.toggling("quiet", in: [["floor"]], places: []), [["floor"], ["quiet"]])
  }

  func testUntickingTakesItOutOfEveryGroupAndDropsEmptyOnes() {
    XCTAssertEqual(TaskRequirementToggle.toggling("home", in: [["home", "campus"], ["home"]], places: []), [["campus"]])
    XCTAssertNil(TaskRequirementToggle.toggling("home", in: [["home"]], places: []))
  }

  /// Nothing can be in two places at once, so a second place is an
  /// alternative to the first rather than a second requirement.
  func testASecondPlaceJoinsTheFirstPlacesGroup() {
    let places: Set = ["home", "campus"]
    XCTAssertEqual(
      TaskRequirementToggle.toggling("campus", in: [["floor"], ["home"]], places: places),
      [["floor"], ["home", "campus"]])
    XCTAssertEqual(TaskRequirementToggle.toggling("home", in: [["floor"]], places: places), [["floor"], ["home"]])
  }

  func testRequiresLooksInEveryGroup() {
    XCTAssertTrue(TaskRequirementToggle.requires("campus", in: [["home", "campus"]]))
    XCTAssertFalse(TaskRequirementToggle.requires("campus", in: nil))
  }
}
