import XCTest

@testable import TaktCore

final class DailyNoteMarkdownTests: XCTestCase {

  private func makeSummary(
    completed: [(Int, String)] = [],
    planned: [Int] = [],
    unfinished: [Int] = [],
    deferred: [Int] = [],
    focusSeconds: Int = 0,
    completedDailyIds: Set<String> = []
  ) -> DayLogAggregator.DaySummary {
    DayLogAggregator.DaySummary(
      key: "2026-08-14",
      day: Date(timeIntervalSince1970: 0),
      completed: completed.map {
        .completed(taskId: $0.0, title: $0.1, at: Date(timeIntervalSince1970: 0))
      },
      plannedTaskIds: planned,
      unfinishedTaskIds: unfinished,
      deferredTaskIds: deferred,
      invalidatedTaskIds: [],
      focusSeconds: focusSeconds,
      completedDailyIds: completedDailyIds
    )
  }

  // MARK: - section

  func testSectionIsWrappedInBothMarkers() {
    let section = DailyNoteMarkdown.section(summary: makeSummary(completed: [(1, "Ship it")]))
    XCTAssertTrue(section.hasPrefix(DailyNoteMarkdown.beginMarker))
    XCTAssertTrue(section.hasSuffix(DailyNoteMarkdown.endMarker))
  }

  func testSectionListsCompletionsAsCheckedItems() {
    let section = DailyNoteMarkdown.section(
      summary: makeSummary(completed: [(1, "Ship it"), (2, "Write tests")]))
    XCTAssertTrue(section.contains("- [x] Ship it"))
    XCTAssertTrue(section.contains("- [x] Write tests"))
  }

  func testSectionSaysSoWhenNothingWasRecorded() {
    let section = DailyNoteMarkdown.section(summary: makeSummary())
    XCTAssertTrue(section.contains("_Nothing recorded._"))
  }

  func testSectionNamesUnfinishedAndDeferredTasks() {
    let section = DailyNoteMarkdown.section(
      summary: makeSummary(planned: [1, 2], unfinished: [1], deferred: [2]),
      titlesByTaskId: [1: "Left over", 2: "Pushed back"]
    )
    XCTAssertTrue(section.contains("- [ ] Left over"))
    XCTAssertTrue(section.contains("- Pushed back"))
  }

  func testSectionIncludesFocusTimeOnlyWhenThereIsSome() {
    XCTAssertTrue(
      DailyNoteMarkdown.section(summary: makeSummary(focusSeconds: 6000)).contains("1h 40m focused"))
    XCTAssertFalse(DailyNoteMarkdown.section(summary: makeSummary()).contains("focused"))
  }

  /// Task titles are arbitrary user text landing in a markdown list. A leading
  /// `#` would otherwise turn the item into a heading and restructure the note.
  func testTitlesThatWouldRestructureTheNoteAreEscaped() {
    let section = DailyNoteMarkdown.section(summary: makeSummary(completed: [(1, "# not a heading")]))
    XCTAssertTrue(section.contains("- [x] \\# not a heading"))
  }

  func testMultiLineTitlesAreCollapsedOntoOneItem() {
    let section = DailyNoteMarkdown.section(
      summary: makeSummary(completed: [(1, "first line\nsecond line")]))
    XCTAssertTrue(section.contains("- [x] first line second line"))
  }

  // MARK: - merged

  func testMergedAppendsWhenTheNoteHasNoManagedBlock() {
    let existing = "# Thursday\n\nSome prose I wrote."
    let merged = DailyNoteMarkdown.merged(
      section: DailyNoteMarkdown.section(summary: makeSummary(completed: [(1, "A")])),
      into: existing
    )
    XCTAssertTrue(merged.hasPrefix("# Thursday"))
    XCTAssertTrue(merged.contains("Some prose I wrote."))
    XCTAssertTrue(merged.contains("- [x] A"))
  }

  func testMergedReplacesAnExistingBlockInPlace() {
    let first = DailyNoteMarkdown.merged(
      section: DailyNoteMarkdown.section(summary: makeSummary(completed: [(1, "A")])),
      into: "# Thursday\n\nProse."
    )
    let second = DailyNoteMarkdown.merged(
      section: DailyNoteMarkdown.section(summary: makeSummary(completed: [(1, "A"), (2, "B")])),
      into: first
    )
    XCTAssertTrue(second.contains("- [x] B"))
    XCTAssertTrue(second.contains("Prose."))
    // Exactly one managed block, not two stacked.
    XCTAssertEqual(occurrences(of: DailyNoteMarkdown.beginMarker, in: second), 1)
    XCTAssertEqual(occurrences(of: DailyNoteMarkdown.endMarker, in: second), 1)
  }

  func testWritingTheSameDayTwiceIsIdempotent() {
    let section = DailyNoteMarkdown.section(summary: makeSummary(completed: [(1, "A")]))
    let once = DailyNoteMarkdown.merged(section: section, into: "# Thursday\n\nProse.")
    let twice = DailyNoteMarkdown.merged(section: section, into: once)
    XCTAssertEqual(once, twice)
  }

  func testMergedPreservesTextOutsideTheBlockOnBothSides() {
    let existing = """
      # Thursday

      Above.

      \(DailyNoteMarkdown.beginMarker)
      stale
      \(DailyNoteMarkdown.endMarker)

      Below.
      """
    let merged = DailyNoteMarkdown.merged(
      section: DailyNoteMarkdown.section(summary: makeSummary(completed: [(1, "A")])),
      into: existing
    )
    XCTAssertTrue(merged.contains("Above."))
    XCTAssertTrue(merged.contains("Below."))
    XCTAssertFalse(merged.contains("stale"))
  }

  /// The important safety property: replacing on a half-open marker would
  /// swallow everything the user wrote below it. A duplicate block they can
  /// delete is a far better failure than prose that is silently gone.
  func testAHalfOpenMarkerNeverSwallowsTheRestOfTheNote() {
    let existing = """
      # Thursday

      \(DailyNoteMarkdown.beginMarker)

      Prose that must survive.
      """
    let merged = DailyNoteMarkdown.merged(
      section: DailyNoteMarkdown.section(summary: makeSummary(completed: [(1, "A")])),
      into: existing
    )
    XCTAssertTrue(merged.contains("Prose that must survive."))
  }

  func testMergedIntoAnEmptyNoteIsJustTheSection() {
    let section = DailyNoteMarkdown.section(summary: makeSummary(completed: [(1, "A")]))
    let merged = DailyNoteMarkdown.merged(section: section, into: "   \n\n ")
    XCTAssertEqual(merged.trimmingCharacters(in: .whitespacesAndNewlines), section)
  }

  private func occurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var searchRange = haystack.startIndex..<haystack.endIndex
    while let found = haystack.range(of: needle, range: searchRange) {
      count += 1
      searchRange = found.upperBound..<haystack.endIndex
    }
    return count
  }
}

final class DailyNotePathTests: XCTestCase {

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
  }

  private var day: Date {
    calendar.date(from: DateComponents(year: 2026, month: 8, day: 14))!
  }

  func testFlatFolderUsesTheFileNameFormatOnly() {
    let path = DailyNotePath.relativePath(
      for: day, format: DailyNoteFormat(fileNameFormat: "yyyy-MM-dd"), calendar: calendar)
    XCTAssertEqual(path, "2026-08-14.md")
  }

  func testAlternativeFileNameFormatsAreHonoured() {
    let path = DailyNotePath.relativePath(
      for: day, format: DailyNoteFormat(fileNameFormat: "dd-MM-yyyy"), calendar: calendar)
    XCTAssertEqual(path, "14-08-2026.md")
  }

  func testSubfolderFormatNestsTheNote() {
    let path = DailyNotePath.relativePath(
      for: day,
      format: DailyNoteFormat(fileNameFormat: "yyyy-MM-dd", folderFormat: "yyyy/MM"),
      calendar: calendar
    )
    XCTAssertEqual(path, "2026/08/2026-08-14.md")
  }

  /// A non-Gregorian system locale must not file the note under a different
  /// year — the formatter is pinned to POSIX for exactly this reason.
  func testFormattingIgnoresTheSystemLocale() {
    var buddhist = Calendar(identifier: .buddhist)
    buddhist.timeZone = TimeZone(secondsFromGMT: 0)!
    let gregorianPath = DailyNotePath.relativePath(
      for: day, format: DailyNoteFormat(fileNameFormat: "yyyy-MM-dd"), calendar: calendar)
    XCTAssertEqual(gregorianPath, "2026-08-14.md")
    // The calendar is an explicit argument, so a caller passing a different one
    // gets that calendar's year rather than a locale-dependent surprise.
    let buddhistPath = DailyNotePath.relativePath(
      for: day, format: DailyNoteFormat(fileNameFormat: "yyyy"), calendar: buddhist)
    XCTAssertEqual(buddhistPath, "2569.md")
  }

  func testPathSeparatorsInTheFileFormatCannotSplitTheComponent() {
    let path = DailyNotePath.relativePath(
      for: day, format: DailyNoteFormat(fileNameFormat: "yyyy/MM"), calendar: calendar)
    XCTAssertEqual(path, "202608.md")
  }

  func testAnEmptyFileFormatFallsBackRatherThanProducingABareExtension() {
    let path = DailyNotePath.relativePath(
      for: day, format: DailyNoteFormat(fileNameFormat: ""), calendar: calendar)
    XCTAssertEqual(path, "daily.md")
  }

  func testWhitespaceOnlyFolderFormatIsTreatedAsFlat() {
    let path = DailyNotePath.relativePath(
      for: day,
      format: DailyNoteFormat(fileNameFormat: "yyyy-MM-dd", folderFormat: "   "),
      calendar: calendar
    )
    XCTAssertEqual(path, "2026-08-14.md")
  }
}
