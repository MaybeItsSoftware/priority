import XCTest

@testable import TaktCore

/// The phones' Find sheet reads its commands and its order from the core.
final class PhonePaletteTests: XCTestCase {
  func testEveryCatalogueCommandFindOffersIsInTheCatalogue() {
    for command in PhonePalette.commands where !command.id.hasPrefix("phone") {
      XCTAssertNotNil(WorkspaceCommandID(rawValue: command.id), command.id)
    }
  }

  func testAQueryPutsTheBestCommandFirstAndRecentsLeadWithNothingTyped() {
    XCTAssertEqual(PhonePalette.rankCommands("today", recents: []).first?.id, "goToday")
    XCTAssertEqual(PhonePalette.rankCommands("", recents: ["phoneSettings"]).first?.id, "phoneSettings")
    XCTAssertEqual(PhonePalette.rankCommands("", recents: []).count, PhonePalette.commands.count)
  }

  func testListsRankByAbbreviation() {
    let lists = [
      PhonePalette.Candidate(title: "Groceries", detail: "Home"),
      PhonePalette.Candidate(title: "Work projects", detail: ""),
    ]
    XCTAssertEqual(PhonePalette.rank("wp", lists), [1])
    XCTAssertEqual(PhonePalette.recording("b", recents: ["a", "b"]), ["b", "a"])
  }
}
