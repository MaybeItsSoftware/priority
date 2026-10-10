import XCTest

@testable import TaktCore

/// What a task and a day look like as AFFiNE documents, and — the part that
/// matters — what happens the second time one is written.
final class AFFiNEDocumentMarkdownTests: XCTestCase {

  private let syncDate = Date(timeIntervalSince1970: 1_755_500_000)
  private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  // MARK: - Day documents

  func testADayIsTitledTheWayTheVaultNamesIt() {
    XCTAssertEqual(
      AFFiNEDocumentMarkdown.dayDocumentTitle(for: syncDate, calendar: utc),
      "2025-08-18"
    )
    XCTAssertEqual(
      AFFiNEDocumentMarkdown.dayDocumentTitle(for: syncDate, pattern: "dd-MM-yyyy", calendar: utc),
      "18-08-2025"
    )
  }

  /// AFFiNE has no block for an HTML comment, so the markers Obsidian relies on
  /// would not survive the round trip. The rendering is shared; the delimiters
  /// are not.
  func testTheCommentMarkersComeOff() {
    let rendered = """
      \(DailyNoteMarkdown.beginMarker)
      ## Log

      **2 done**
      \(DailyNoteMarkdown.endMarker)
      """

    let section = AFFiNEDocumentMarkdown.daySection(from: rendered)

    XCTAssertFalse(section.contains(DailyNoteMarkdown.beginMarker))
    XCTAssertFalse(section.contains(DailyNoteMarkdown.endMarker))
    XCTAssertTrue(section.hasPrefix("## Log"))
    XCTAssertTrue(section.contains("**2 done**"))
  }

  // MARK: - Merging

  func testWritingADayTwiceReplacesItRatherThanStackingIt() {
    let first = AFFiNEDocumentMarkdown.merged(section: "## Log\n\n**1 done**", into: "")
    let second = AFFiNEDocumentMarkdown.merged(section: "## Log\n\n**4 done**", into: first)

    XCTAssertEqual(second.components(separatedBy: "## Log").count - 1, 1)
    XCTAssertTrue(second.contains("**4 done**"))
    XCTAssertFalse(second.contains("**1 done**"))
  }

  /// The rule that makes this safe to run against a document someone writes in:
  /// everything outside Priority's heading is theirs.
  func testWhatTheUserWroteAroundTheBlockSurvives() {
    let existing = """
      Woke up late.

      ## Log

      **1 done**

      ## Evening

      Read two chapters.
      """

    let merged = AFFiNEDocumentMarkdown.merged(section: "## Log\n\n**5 done**", into: existing)

    XCTAssertTrue(merged.contains("Woke up late."))
    XCTAssertTrue(merged.contains("## Evening"))
    XCTAssertTrue(merged.contains("Read two chapters."))
    XCTAssertTrue(merged.contains("**5 done**"))
    XCTAssertFalse(merged.contains("**1 done**"))
  }

  /// A `###` under Priority's heading belongs to Priority and goes with it; the
  /// block ends at the next heading of the same level or shallower.
  func testASubheadingInsideTheBlockIsReplacedWithIt() {
    let existing = """
      ## Log

      **1 done**

      ### Dailies

      - [x] Stretch

      # Journal

      Kept.
      """

    let merged = AFFiNEDocumentMarkdown.merged(section: "## Log\n\n**2 done**", into: existing)

    XCTAssertFalse(merged.contains("### Dailies"))
    XCTAssertTrue(merged.contains("# Journal"))
    XCTAssertTrue(merged.contains("Kept."))
  }

  func testABlockIsAppendedToADocumentThatHasNoneYet() {
    let merged = AFFiNEDocumentMarkdown.merged(
      section: "## Log\n\n**3 done**", into: "Just some notes.")

    XCTAssertTrue(merged.hasPrefix("Just some notes."))
    XCTAssertTrue(merged.contains("## Log"))
  }

  /// `#Log` is not a heading, and a heading at a different level is a different
  /// heading. Matching either would replace text nobody asked us to touch.
  func testNearMissesAreNotTreatedAsTheBlock() {
    let existing = "#Log\n\nnot a heading\n\n### Log\n\nnor this one"
    let merged = AFFiNEDocumentMarkdown.merged(section: "## Log\n\n**1 done**", into: existing)

    XCTAssertTrue(merged.contains("not a heading"))
    XCTAssertTrue(merged.contains("nor this one"))
    XCTAssertTrue(merged.contains("**1 done**"))
  }
}
