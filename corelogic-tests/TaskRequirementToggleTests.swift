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
    XCTAssertTrue(TaskRequirementToggle.requires("campus", in: [["!campus"]]))
    XCTAssertFalse(TaskRequirementToggle.requires("campus", in: nil))
  }

  /// `!` ticks a condition as not holding: a group of its own even for a
  /// place, turned round when it was required as itself, and ticked off
  /// when it was already "not".
  func testNegatingTicksNotAndUnticksIt() {
    let places: Set = ["home", "campus"]
    XCTAssertEqual(TaskRequirementToggle.negating("home", in: nil), [["!home"]])
    XCTAssertEqual(TaskRequirementToggle.negating("home", in: [["campus", "home"], ["floor"]]), [["campus"], ["floor"], ["!home"]])
    XCTAssertNil(TaskRequirementToggle.negating("home", in: [["!home"]]))
    // A place ticked after a "not" place is not an alternative to it.
    XCTAssertEqual(TaskRequirementToggle.toggling("campus", in: [["!home"]], places: places), [["!home"], ["campus"]])
  }

  /// Ticking a condition required as "not" takes it off, as ticking one
  /// required as itself does.
  func testTickingANegatedConditionUnticksIt() {
    XCTAssertEqual(TaskRequirementToggle.toggling("home", in: [["!home"], ["floor"]], places: []), [["floor"]])
    XCTAssertEqual(TaskRequirementToggle.requirement(of: "home", in: [["floor"], ["!home"]]), TaskRequirement("!home"))
  }

  func testARequirementReadsAndWritesItsNegation() {
    let not = TaskRequirement("!home")
    XCTAssertEqual(not, TaskRequirement(conditionID: "home", isNegated: true))
    XCTAssertEqual(not.member, "!home")
    XCTAssertEqual(TaskRequirement("home").member, "home")
    XCTAssertTrue(not.isMet(available: ["campus"]))
    XCTAssertFalse(not.isMet(available: ["home"]))
    XCTAssertEqual(TaskRequirement.label(group: ["campus", "!quiet"]) { $0.capitalized }, "Campus or not Quiet")
    XCTAssertEqual(TaskRequirement.label("!gone") { _ in nil }, "not Missing condition")
    XCTAssertTrue(TaskRequirement.isMet(group: ["home", "!home"], available: []))
    XCTAssertFalse(TaskRequirement.isMet(group: ["campus", "!quiet"], available: ["quiet"]))
  }
}
