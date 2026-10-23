import TaktCore
import XCTest

final class ConditionsPaneLayoutTests: XCTestCase {
  private let sections = [
    ConditionsPaneLayout.Section(id: "location", conditionIDs: ["home", "campus"]),
    ConditionsPaneLayout.Section(id: "equipment", conditionIDs: ["mat"]),
    ConditionsPaneLayout.Section(id: "empty", conditionIDs: []),
  ]

  func testRowsWalkBothHalvesAndFoldHeadings() {
    let rows = ConditionsPaneLayout.rows(
      available: ["campus"], sections: sections, folded: ["location"], archived: ["old"], showsArchived: false)
    XCTAssertEqual(rows, [.time, .available("campus"), .expiry, .add, .folded("location"), .condition("mat"), .archived])
    // Free time follows where you are, before the other settings and the
    // properties.
    XCTAssertEqual(
      ConditionsPaneLayout.rows(
        available: ["laptop"], sections: [], folded: [], archived: [], showsArchived: false, hasPlaces: true,
        hasTimeLimit: true),
      [.location, .time, .finishOnly, .available("laptop"), .expiry, .add])
    let shown = ConditionsPaneLayout.rows(
      available: [], sections: sections, folded: [], archived: ["old"], showsArchived: true)
    XCTAssertEqual(
      shown, [.time, .expiry, .add, .condition("home"), .condition("campus"), .condition("mat"), .archived, .condition("old")])
    XCTAssertEqual(
      ConditionsPaneLayout.rows(available: [], sections: [], folded: [], archived: [], showsArchived: true), [.time, .expiry, .add])
  }

  /// How each day starts sits after the expiry, before the second half; what
  /// it starts with only while it starts afresh, and a cursor left there
  /// when it stops lands on the switch.
  func testHowEachDayStartsFollowsTheExpiry() {
    let off = ConditionsPaneLayout.rows(
      available: [], sections: [], folded: [], archived: [], showsArchived: false, dayStart: true)
    XCTAssertEqual(off, [.time, .expiry, .dayStart, .dayStartHour, .add])
    let on = ConditionsPaneLayout.rows(
      available: [], sections: [], folded: [], archived: [], showsArchived: false, dayStart: true, startsAfresh: true)
    XCTAssertEqual(on, [.time, .expiry, .dayStart, .dayStartHour, .dayStartConditions, .add])
    XCTAssertEqual(ConditionsPaneLayout.landing(.dayStartConditions, in: off, sections: []), .dayStart)
    XCTAssertNil(ConditionsPaneRow.dayStartHour.conditionID)
  }

  func testACursorWhoseRowWentLandsOnTheSameCondition() {
    let folded = ConditionsPaneLayout.rows(
      available: [], sections: sections, folded: ["location"], archived: ["old"], showsArchived: false)
    // Folded away: onto its heading.
    XCTAssertEqual(ConditionsPaneLayout.landing(.condition("campus"), in: folded, sections: sections), .folded("location"))
    // Out of "Available now": onto the same condition below.
    XCTAssertEqual(ConditionsPaneLayout.landing(.available("mat"), in: folded, sections: sections), .condition("mat"))
    // Archived and hidden: onto the archived heading.
    XCTAssertEqual(ConditionsPaneLayout.landing(.condition("old"), in: folded, sections: sections), .archived)
    // A heading unfolded: onto its first condition.
    let open = ConditionsPaneLayout.rows(
      available: [], sections: sections, folded: [], archived: [], showsArchived: false)
    XCTAssertEqual(ConditionsPaneLayout.landing(.folded("location"), in: open, sections: sections), .condition("home"))
    XCTAssertEqual(ConditionsPaneLayout.landing(nil, in: open, sections: sections), .time)
  }

  func testARowKnowsItsSection() {
    XCTAssertEqual(ConditionsPaneLayout.section(of: .condition("mat"), in: sections)?.id, "equipment")
    XCTAssertEqual(ConditionsPaneLayout.section(of: .folded("location"), in: sections)?.id, "location")
    XCTAssertNil(ConditionsPaneLayout.section(of: .add, in: sections))
  }
}
