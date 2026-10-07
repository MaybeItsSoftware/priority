import XCTest

@testable import TaktCore

final class ManagedMarkdownBlockTests: XCTestCase {
  private let block = ManagedMarkdownBlock.takt

  func testWrapPutsTheMarkersOnTheirOwnLines() {
    XCTAssertEqual(
      block.wrap("body"),
      "<!-- priority:begin -->\nbody\n<!-- priority:end -->")
  }

  func testAnEmptyDocumentBecomesJustTheBlock() {
    XCTAssertEqual(block.merging(body: "x", into: ""), block.wrap("x") + "\n")
    XCTAssertEqual(block.merging(body: "x", into: "  \n\n"), block.wrap("x") + "\n")
  }

  func testAppendsAfterAUsersProseWhenThereIsNoBlockYet() {
    let merged = block.merging(body: "ours", into: "# My note\n\nTheir words.\n")
    XCTAssertEqual(merged, "# My note\n\nTheir words.\n\n" + block.wrap("ours") + "\n")
  }

  /// The whole point: text on either side of the markers is the user's and
  /// comes back exactly as it went in.
  func testReplacesOnlyTheBlockAndKeepsEverythingAroundIt() {
    let existing =
      "Above, with trailing spaces   \n" + block.wrap("old") + "\n\nBelow\n- their list\n"
    let merged = block.merging(body: "new", into: existing)
    XCTAssertEqual(merged, "Above, with trailing spaces   \n" + block.wrap("new") + "\n\nBelow\n- their list\n")
  }

  func testRewritingTheSameBodyIsIdempotent() {
    let once = block.merging(body: "same", into: "intro\n")
    XCTAssertEqual(block.merging(body: "same", into: once), once)
  }

  func testAHalfOpenMarkerIsNotABlockSoAFreshOneIsAppended() {
    let existing = "<!-- priority:begin -->\nthe user's prose with no end marker\n"
    XCTAssertFalse(block.contains(existing))
    let merged = block.merging(body: "ours", into: existing)
    XCTAssertTrue(merged.hasPrefix(existing.trimmingCharacters(in: .whitespacesAndNewlines)))
    XCTAssertTrue(merged.hasSuffix(block.wrap("ours") + "\n"))
  }

  func testAnEndMarkerBeforeTheBeginMarkerDoesNotCount() {
    let existing = "<!-- priority:end -->\nmiddle\n<!-- priority:begin -->\n"
    XCTAssertFalse(block.contains(existing))
  }

  func testContainsIsTrueForAWellFormedBlock() {
    XCTAssertTrue(block.contains("x\n" + block.wrap("y") + "\nz"))
    XCTAssertFalse(block.contains("nothing here"))
  }

  func testDailyNoteMarkdownStillMergesThroughTheSameMarkers() {
    let section = DailyNoteMarkdown.beginMarker + "\n## Log\n" + DailyNoteMarkdown.endMarker
    let merged = DailyNoteMarkdown.merged(section: section, into: "hello\n" + block.wrap("old") + "\n")
    XCTAssertEqual(merged, "hello\n" + section + "\n")
  }

  func testCustomMarkersAreHonoured() {
    let custom = ManagedMarkdownBlock(beginMarker: "<!-- a -->", endMarker: "<!-- /a -->")
    let merged = custom.merging(body: "b", into: "<!-- a -->\nold\n<!-- /a -->")
    XCTAssertEqual(merged, "<!-- a -->\nb\n<!-- /a -->")
    XCTAssertFalse(block.contains(merged))
  }
}
