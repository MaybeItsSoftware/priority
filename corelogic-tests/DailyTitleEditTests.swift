import XCTest

@testable import TaktCore

/// The rename rules, and the bug they exist for.
///
/// The settings editor bound its title field straight through to the store, so
/// `DailyLogService.updateDaily` ran on every keystroke — and that method trims
/// its input and ignores an empty result. Both are correct rules for a finished
/// title. Applied to a draft they made the field impossible to type in.
final class DailyTitleEditTests: XCTestCase {

  // MARK: - The bug

  /// The exact reported symptom. Typing "Morning" then a space stored the
  /// trimmed "Morning", the field re-read the stored value, and the space
  /// vanished as it was typed — so the next character landed against the word
  /// and "Morning pages" came out as "Morningpages". No multi-word daily could
  /// be renamed at all.
  ///
  /// Nothing here rejects the trailing space: a draft is not committed until
  /// the user says so, and by then the space is meaningless anyway.
  func testATrailingSpaceIsNotACommit() {
    XCTAssertNil(
      DailyTitleEdit.committed(draft: "Morning ", original: "Morning"),
      "committing a word plus a trailing space is committing the same word")
  }

  func testAMultiWordRenameCommitsIntact() {
    XCTAssertEqual(
      DailyTitleEdit.committed(draft: "Morning pages", original: "Morning"),
      "Morning pages")
  }

  /// The other half of the same bug: clearing the field to retype snapped the
  /// old name straight back, because an empty write was ignored and the field
  /// re-read the store. Emptiness is still refused — but now at commit time,
  /// where it means "I changed my mind", not mid-word.
  func testAnEmptyDraftCommitsNothing() {
    XCTAssertNil(DailyTitleEdit.committed(draft: "", original: "Morning"))
    XCTAssertNil(DailyTitleEdit.committed(draft: "   ", original: "Morning"))
  }

  // MARK: - Not churning the file

  /// `renameDaily` takes a file lock, rewrites `dailies.json` and bumps the
  /// revision the whole Daily view re-renders on. Doing all that to store a
  /// value that is already there is worth one comparison to avoid.
  func testAnUnchangedDraftCommitsNothing() {
    XCTAssertNil(DailyTitleEdit.committed(draft: "Morning", original: "Morning"))
  }

  func testSurroundingWhitespaceDoesNotMakeADraftLookChanged() {
    XCTAssertNil(DailyTitleEdit.committed(draft: "  Morning  ", original: "Morning"))
  }

  // MARK: - Ordinary edits

  func testTrimsWhatItCommits() {
    XCTAssertEqual(
      DailyTitleEdit.committed(draft: "  Evening walk  ", original: "Morning"),
      "Evening walk")
  }

  func testInternalWhitespaceIsLeftAlone() {
    XCTAssertEqual(
      DailyTitleEdit.committed(draft: "Read  two  pages", original: "Read"),
      "Read  two  pages")
  }

  func testRenamingToSomethingCompletelyDifferentWorks() {
    XCTAssertEqual(
      DailyTitleEdit.committed(draft: "Stretch", original: "Morning"),
      "Stretch")
  }
}
