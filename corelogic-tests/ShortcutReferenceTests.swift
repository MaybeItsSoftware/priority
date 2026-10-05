import XCTest

@testable import TaktCore

/// `ShortcutReference` renders a binding token as it is read on a Mac
/// keyboard. Every key cap the workspace draws — palette, reference, tooltips,
/// menus — goes through it.
final class ShortcutReferenceTests: XCTestCase {

  // MARK: - Rendering

  func testModifiersRenderInTheOrderMacOSWritesThem() {
    // Stored ctrl, cmd, option, shift — displayed control, option, shift,
    // command. The binding format and the convention disagree, deliberately.
    XCTAssertEqual(ShortcutReference.display(token: "cmd+up"), "⌘↑")
    XCTAssertEqual(ShortcutReference.display(token: "shift+enter"), "⇧↩")
    XCTAssertEqual(ShortcutReference.display(token: "option+enter"), "⌥↩")
    XCTAssertEqual(ShortcutReference.display(token: "ctrl+left"), "⌃←")
  }

  func testNamedKeysUseTheirGlyph() {
    XCTAssertEqual(ShortcutReference.display(token: "escape"), "⎋")
    XCTAssertEqual(ShortcutReference.display(token: "tab"), "⇥")
    XCTAssertEqual(ShortcutReference.display(token: "delete"), "⌫")
    XCTAssertEqual(ShortcutReference.display(token: "space"), "Space")
    // Stored as a word because the binding format is comma-separated.
    XCTAssertEqual(ShortcutReference.display(token: "comma"), ",")
  }

  /// Spaced, so `dd` reads as two presses. Unspaced it looks like a chord, and
  /// somebody presses `d` and concludes the shortcut is broken.
  func testTwoKeySequencesRenderAsTwoPresses() {
    XCTAssertEqual(ShortcutReference.display(token: "dd"), "D D")
    XCTAssertEqual(ShortcutReference.display(token: "gc"), "G C")
  }

  func testAlternativesAreSplitOnCommas() {
    XCTAssertEqual(ShortcutReference.displayKeys(forBinding: "down,j"), ["↓", "J"])
    XCTAssertEqual(ShortcutReference.displayKeys(forBinding: "cmd+up,cmd+k"), ["⌘↑", "⌘K"])
  }
}
