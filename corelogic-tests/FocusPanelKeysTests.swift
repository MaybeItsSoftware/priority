import XCTest

@testable import TaktCore

/// The focus panel's list answers to the window's keys, translated onto its
/// own cursor. These pin the translation for the keys the README promises,
/// and that a key the panel has no use for is neither run nor held.
final class FocusPanelKeysTests: XCTestCase {
  private func action(_ key: String, on surface: WorkspaceCommandSurface = .outline) -> FocusPanelAction? {
    FocusPanelKeys.action(forKey: key, on: surface)
  }

  func testTheCursorKeysWalkTheList() {
    for surface in [WorkspaceCommandSurface.today, .outline] {
      XCTAssertEqual(action("down", on: surface), .step(1))
      XCTAssertEqual(action("j", on: surface), .step(1))
      XCTAssertEqual(action("up", on: surface), .step(-1))
      XCTAssertEqual(action("k", on: surface), .step(-1))
      XCTAssertEqual(action("pagedown", on: surface), .step(8))
      XCTAssertEqual(action("ctrl+u", on: surface), .step(-8))
      XCTAssertEqual(action("home", on: surface), .first)
      XCTAssertEqual(action("shift+g", on: surface), .last)
      XCTAssertEqual(action("right", on: surface), .right)
      XCTAssertEqual(action("left", on: surface), .left)
      XCTAssertEqual(action(":", on: surface), .numberJump)
    }
    // Today's own: l and h fold and step, as they do in the window's Today.
    XCTAssertEqual(action("l", on: .today), .right)
    XCTAssertEqual(action("h", on: .today), .left)
  }

  func testTheQuickEditKeysAreTheWindowsOwn() {
    XCTAssertEqual(action("ee"), .edit(.title))
    XCTAssertEqual(action("f2"), .edit(.title))
    XCTAssertEqual(action("dd"), .edit(.due))
    XCTAssertEqual(action("cmd+d"), .edit(.due))
    XCTAssertEqual(action("option+s"), .edit(.start))
    XCTAssertEqual(action("option+t"), .edit(.estimate))
    XCTAssertEqual(action("nn"), .edit(.notes))
    XCTAssertEqual(action("tt"), .edit(.tags))
    XCTAssertEqual(action("dr"), .edit(.recurrence))
    XCTAssertEqual(action("cc"), .conditions)
    XCTAssertEqual(action("td"), .due(days: 0))
    XCTAssertEqual(action("tm"), .due(days: 1))
    XCTAssertEqual(action("cd"), .clearDue)
  }

  func testDigitsSetThePriorityAndZeroClearsIt() {
    for digit in 1...4 {
      XCTAssertEqual(action("\(digit)"), .priority(digit))
      XCTAssertEqual(action("\(digit)", on: .today), .priority(digit))
    }
    XCTAssertEqual(action("0"), .priority(0))
    // `-` sends it to the back: priority -1.
    XCTAssertEqual(action("-"), .priority(-1))
    XCTAssertNil(action("5"))
  }

  func testCompletingStartingAndLeaving() {
    XCTAssertEqual(action("space"), .complete)
    XCTAssertEqual(action("x"), .complete)
    XCTAssertEqual(action("gf"), .start)
    XCTAssertEqual(action("gf", on: .today), .start)
    XCTAssertEqual(action("enter"), .add)
    XCTAssertEqual(action("/"), .search)
    XCTAssertEqual(action("escape"), .dismiss)
    XCTAssertEqual(action("cmd+t"), .goToday)
    XCTAssertEqual(action("cmd+p"), .chooseList)
    XCTAssertEqual(action("cmd+shift+{"), .place(-1))
    XCTAssertEqual(action("cmd+shift+}"), .place(1))
    XCTAssertEqual(action("cmd+z"), .undo)
  }

  /// `xx` extracts a branch in the window; the panel has no use for it, so
  /// `x` must not wait to see whether a second follows.
  func testOnlyThePanelsOwnSequencesAreHeld() {
    let sequences = FocusPanelKeys.sequences(on: .outline)
    XCTAssertTrue(sequences.contains("dd"))
    XCTAssertTrue(sequences.contains("ee"))
    XCTAssertTrue(sequences.contains("cc"))
    XCTAssertTrue(sequences.contains("gg"))
    XCTAssertFalse(sequences.contains("xx"))
    XCTAssertFalse(sequences.contains("mm"))
    XCTAssertFalse(sequences.contains("ww"))
  }

  func testOnlyChordedEditsReachIntoTheField() {
    XCTAssertTrue(FocusPanelKeys.reachesFromField(.edit(.due), key: "cmd+d"))
    XCTAssertTrue(FocusPanelKeys.reachesFromField(.edit(.estimate), key: "option+t"))
    XCTAssertTrue(FocusPanelKeys.reachesFromField(.edit(.title), key: "f2"))
    XCTAssertTrue(FocusPanelKeys.reachesFromField(.chooseList, key: "cmd+p"))
    XCTAssertFalse(FocusPanelKeys.reachesFromField(.edit(.due), key: "dd"))
    XCTAssertFalse(FocusPanelKeys.reachesFromField(.edit(.title), key: "f"))
    XCTAssertFalse(FocusPanelKeys.reachesFromField(.priority(1), key: "1"))
    // Undo inside the field is the text's.
    XCTAssertFalse(FocusPanelKeys.reachesFromField(.undo, key: "cmd+z"))
  }

  /// ⌃T and ⌘O act on the panel's row, from the rows and the field alike.
  func testPlanTodayAndOpenLinkAreThePanels() {
    XCTAssertEqual(FocusPanelKeys.action(forKey: "ctrl+t", on: .today), .planToday)
    XCTAssertEqual(FocusPanelKeys.action(forKey: "cmd+o", on: .outline), .openLink)
    XCTAssertTrue(FocusPanelKeys.reachesFromField(.planToday, key: "ctrl+t"))
    XCTAssertTrue(FocusPanelKeys.reachesFromField(.openLink, key: "cmd+o"))
  }

  /// The chords the main menu would run on the window's selection are never
  /// let through to it from the panel; the app's own and the views' are.
  func testSelectionChordsAreTheTaskAndListCommands() {
    XCTAssertTrue(FocusPanelKeys.isSelectionChord("cmd+delete", on: .today))
    XCTAssertTrue(FocusPanelKeys.isSelectionChord("cmd+shift+m", on: .outline))
    XCTAssertTrue(FocusPanelKeys.isSelectionChord("cmd+option+a", on: .outline))
    XCTAssertFalse(FocusPanelKeys.isSelectionChord("cmd+shift+.", on: .today))
    XCTAssertFalse(FocusPanelKeys.isSelectionChord("cmd+q", on: .today))
    XCTAssertFalse(FocusPanelKeys.isSelectionChord("delete", on: .today))
  }

  func testNumberJumpIsVimsColonN() {
    XCTAssertEqual(FocusPanelKeys.numberedIndex(3, count: 5), 2)
    XCTAssertEqual(FocusPanelKeys.numberedIndex(0, count: 5), 0)
    XCTAssertEqual(FocusPanelKeys.numberedIndex(99, count: 5), 4)
    XCTAssertNil(FocusPanelKeys.numberedIndex(1, count: 0))
  }
}
