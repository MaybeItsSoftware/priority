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
    XCTAssertEqual(rows, [.available("campus"), .add, .folded("location"), .condition("mat"), .archived])
    let shown = ConditionsPaneLayout.rows(
      available: [], sections: sections, folded: [], archived: ["old"], showsArchived: true)
    XCTAssertEqual(
      shown, [.add, .condition("home"), .condition("campus"), .condition("mat"), .archived, .condition("old")])
    XCTAssertEqual(
      ConditionsPaneLayout.rows(available: [], sections: [], folded: [], archived: [], showsArchived: true), [.add])
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
    XCTAssertEqual(ConditionsPaneLayout.landing(nil, in: open, sections: sections), .add)
  }

  func testARowKnowsItsSection() {
    XCTAssertEqual(ConditionsPaneLayout.section(of: .condition("mat"), in: sections)?.id, "equipment")
    XCTAssertEqual(ConditionsPaneLayout.section(of: .folded("location"), in: sections)?.id, "location")
    XCTAssertNil(ConditionsPaneLayout.section(of: .add, in: sections))
  }
}
