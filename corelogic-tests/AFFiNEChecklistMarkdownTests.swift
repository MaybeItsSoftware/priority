import XCTest

@testable import TaktCore

/// Tasks as AFFiNE todo blocks, and — the half that makes it two-way — reading
/// back what someone ticked.
final class AFFiNEChecklistMarkdownTests: XCTestCase {

  private func task(
    _ id: Int,
    _ title: String,
    depth: Int = 0,
    list: String = "12"
  ) -> AFFiNEChecklistTask {
    AFFiNEChecklistTask(
      id: id,
      title: title,
      permalink: "https://checkvist.com/checklists/\(list)#t\(id)",
      depth: depth
    )
  }

  // MARK: - Rendering

  func testTasksRenderAsTodoBlocksCarryingTheirPermalink() {
    let section = AFFiNEChecklistMarkdown.section(tasks: [
      task(34, "Write the release notes"),
      task(35, "Draft the summary", depth: 1),
    ])

    XCTAssertEqual(
      section,
      """
      ## Tasks

      - [ ] [Write the release notes](https://checkvist.com/checklists/12#t34)
        - [ ] [Draft the summary](https://checkvist.com/checklists/12#t35)
      """
    )
  }

  /// An offline task has no list, so there is no permalink — and no way to
  /// match a tick back to it. It still belongs in the list.
  func testATaskWithNoPermalinkIsStillWritten() {
    let section = AFFiNEChecklistMarkdown.section(tasks: [
      AFFiNEChecklistTask(id: -3, title: "Offline task", permalink: nil)
    ])

    XCTAssertTrue(section.contains("- [ ] Offline task"))
  }

  func testAnEmptyListSaysSoRatherThanWritingNothing() {
    XCTAssertTrue(AFFiNEChecklistMarkdown.section(tasks: []).contains("_Nothing open._"))
  }

  // MARK: - Reading

  func testTickedBoxesAreReadBackByTaskId() {
    let markdown = """
      Some notes of my own.

      ## Tasks

      - [x] [Ship the DMG](https://checkvist.com/checklists/12#t31)
      - [ ] [Write the release notes](https://checkvist.com/checklists/12#t34)
        - [X] [Draft the summary](https://checkvist.com/checklists/12#t35)

      ## Evening

      - [x] [Not ours](https://example.com/x#t99)
      """

    XCTAssertEqual(AFFiNEChecklistMarkdown.tickedTaskIds(in: markdown), [31, 35])
  }

  /// The reason each item carries a link rather than just its text: AFFiNE's
  /// exporter backslash-escapes every ASCII punctuation character in a label,
  /// so the text that comes back is never the text that was sent.
  func testAnExportEscapedLineStillResolvesToItsTask() {
    let markdown = """
      ## Tasks

      - [x] [Ship the DMG \\(v1\\.2\\)](https://checkvist.com/checklists/12#t31)
      """

    let items = AFFiNEChecklistMarkdown.items(in: markdown)
    XCTAssertEqual(items.first?.taskId, 31)
    XCTAssertEqual(items.first?.title, "Ship the DMG (v1.2)")
    XCTAssertEqual(AFFiNEChecklistMarkdown.tickedTaskIds(in: markdown), [31])
  }

  func testALabelContainingABracketDoesNotEndTheLinkEarly() {
    let round = AFFiNEChecklistMarkdown.section(tasks: [task(7, "Fix [urgent] thing")])
    let items = AFFiNEChecklistMarkdown.items(in: round)

    XCTAssertEqual(items.first?.taskId, 7)
    XCTAssertEqual(items.first?.title, "Fix [urgent] thing")
  }

  func testItemsOutsideTheSectionAreIgnored() {
    let markdown = """
      - [x] [Above the section](https://checkvist.com/checklists/12#t1)

      ## Tasks

      - [ ] [In it](https://checkvist.com/checklists/12#t2)
      """

    XCTAssertEqual(AFFiNEChecklistMarkdown.items(in: markdown).map(\.taskId), [2])
  }

  func testADocumentWithNoSectionReadsAsNothingRatherThanEverything() {
    XCTAssertTrue(AFFiNEChecklistMarkdown.items(in: "Just prose.\n\n- [x] a todo").isEmpty)
  }

  // MARK: - What Priority does not own

  /// A line typed into the section by hand is not Priority's to delete, so it
  /// is read out and put back.
  func testHandWrittenItemsAreCarriedThrough() {
    let markdown = """
      ## Tasks

      - [ ] [Write the release notes](https://checkvist.com/checklists/12#t34)
      - [ ] buy milk
      remember to call the bank
      """

    let carried = AFFiNEChecklistMarkdown.unownedLines(in: markdown)
    XCTAssertEqual(carried, ["- [ ] buy milk", "remember to call the bank"])

    let rewritten = AFFiNEChecklistMarkdown.section(
      tasks: [task(34, "Write the release notes")], carriedOver: carried)
    XCTAssertTrue(rewritten.contains("- [ ] buy milk"))
    XCTAssertTrue(rewritten.contains("remember to call the bank"))
  }

  func testOurOwnEmptyPlaceholderIsNotCarriedBack() {
    let markdown = "## Tasks\n\n_Nothing open._"
    XCTAssertTrue(AFFiNEChecklistMarkdown.unownedLines(in: markdown).isEmpty)
  }

  // MARK: - Change detection

  /// The comparison has to survive a round trip through AFFiNE, or every sync
  /// would rewrite the document and churn its history for nothing.
  func testAnUnchangedListMatchesItsExportEvenAfterEscaping() {
    let tasks = [task(31, "Ship the DMG (v1.2)"), task(34, "Review the sync PR", depth: 1)]
    let exported = """
      ## Tasks

      - [ ] [Ship the DMG \\(v1\\.2\\)](https://checkvist.com/checklists/12#t31)
        - [ ] [Review the sync PR](https://checkvist.com/checklists/12#t34)
      """

    XCTAssertTrue(
      AFFiNEChecklistMarkdown.matches(
        AFFiNEChecklistMarkdown.items(in: exported), tasks: tasks))
  }

  func testAChangedListDoesNotMatch() {
    let exported = """
      ## Tasks

      - [ ] [Ship the DMG](https://checkvist.com/checklists/12#t31)
      """

    let items = AFFiNEChecklistMarkdown.items(in: exported)
    XCTAssertFalse(
      AFFiNEChecklistMarkdown.matches(items, tasks: [task(31, "Ship the DMG"), task(34, "New")]),
      "a task added in Priority is a change")
    XCTAssertFalse(
      AFFiNEChecklistMarkdown.matches(items, tasks: [task(31, "Ship the DMG v2")]),
      "a reworded task is a change")
    XCTAssertFalse(
      AFFiNEChecklistMarkdown.matches(items, tasks: [task(31, "Ship the DMG", depth: 1)]),
      "a task that moved under a parent is a change")
  }

  /// A ticked box is never "no change": it is the signal to close something.
  func testATickedItemNeverMatches() {
    let exported = "## Tasks\n\n- [x] [Ship the DMG](https://checkvist.com/checklists/12#t31)"
    XCTAssertFalse(
      AFFiNEChecklistMarkdown.matches(
        AFFiNEChecklistMarkdown.items(in: exported), tasks: [task(31, "Ship the DMG")]))
  }

  // MARK: - Permalinks

  func testTaskIdsComeOffThePermalinkFragment() {
    XCTAssertEqual(
      AFFiNEChecklistMarkdown.taskId(inPermalink: "https://checkvist.com/checklists/12#t34"), 34)
    // Self-hosted, or a link the user rewrote: the fragment is what matters.
    XCTAssertEqual(AFFiNEChecklistMarkdown.taskId(inPermalink: "https://elsewhere/x#t9"), 9)
    XCTAssertNil(AFFiNEChecklistMarkdown.taskId(inPermalink: "https://checkvist.com/checklists/12"))
    XCTAssertNil(AFFiNEChecklistMarkdown.taskId(inPermalink: "https://example.com/#tasks"))
  }
}
