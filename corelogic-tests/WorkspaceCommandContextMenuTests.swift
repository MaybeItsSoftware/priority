import XCTest

@testable import TaktCore

/// The keys the sidebar's context menu shows beside its items, read from the
/// catalogue as Zed's project panel menu reads its keymap.
final class WorkspaceCommandContextMenuTests: XCTestCase {
  private func key(_ id: WorkspaceCommandID) -> WorkspaceCommand.MenuKeyEquivalent? {
    WorkspaceCommandCatalog.defaults.first { $0.id == id }?.contextMenuKeyEquivalent(on: .sidebar)
  }

  private func equivalent(_ key: String, _ modifiers: [String] = []) -> WorkspaceCommand.MenuKeyEquivalent {
    WorkspaceCommand.MenuKeyEquivalent(key: key, modifiers: modifiers)
  }

  /// The panel's own plain keys, not the chords that also reach the command:
  /// `%` and `d`, as Zed's menu says beside New File and New Directory.
  func testTheSidebarsOwnPlainKeysWin() {
    XCTAssertEqual(key(.listNew), equivalent("%"))
    XCTAssertEqual(key(.folderNew), equivalent("d"))
    XCTAssertEqual(key(.listRename), equivalent("f2"))
    XCTAssertEqual(key(.listDelete), equivalent("delete"))
    XCTAssertEqual(key(.listIcon), equivalent("i", ["shift"]))
  }

  /// A two-key sequence cannot be a menu's key, so the chord is shown.
  func testASequenceGivesWayToTheCommandsChord() {
    XCTAssertEqual(key(.listSettings), equivalent("i", ["cmd", "option"]))
    XCTAssertEqual(key(.listArchive), equivalent("a", ["cmd", "option"]))
  }

  func testSurfaceScopedChordsAreShown() {
    XCTAssertEqual(key(.listMoveUp), equivalent("up", ["option"]))
    XCTAssertEqual(key(.listMoveDown), equivalent("down", ["option"]))
    XCTAssertEqual(key(.folderExpandAll), equivalent("right", ["cmd"]))
    XCTAssertEqual(key(.folderCollapseAll), equivalent("left", ["cmd"]))
  }

  /// A rebound key is the one the menu shows, because it is read from the
  /// command as bound rather than written beside the item.
  func testAReboundKeyIsTheOneShown() {
    let rebound = WorkspaceCommand(
      id: .folderNew, title: "Create a folder", group: "Lists", keys: ["cmd+option+n"],
      surfaceKeys: [.sidebar: ["shift+n"]])
    XCTAssertEqual(rebound.contextMenuKeyEquivalent(on: .sidebar), equivalent("n", ["shift"]))
  }

  func testSequencesAndUnknownModifiersAreNotDrawable() {
    XCTAssertFalse(WorkspaceCommand.isMenuDrawable("oo"))
    XCTAssertFalse(WorkspaceCommand.isMenuDrawable("hyper+k"))
    XCTAssertTrue(WorkspaceCommand.isMenuDrawable("cmd+shift++"))
    XCTAssertTrue(WorkspaceCommand.isMenuDrawable("f2"))
  }
}

/// A list's icon is a symbol's name or an emoji, in the same slot.
final class WorkspaceListIconNameTests: XCTestCase {
  func testSymbolNamesAreNotEmoji() {
    for name in ["list.bullet", "leaf", "figure.run", "1.circle", "a"] {
      XCTAssertFalse(WorkspaceListIconName.isEmoji(name), name)
    }
  }

  func testEmojiAreRecognisedIncludingSequences() {
    for name in ["🌱", "📚", "❤️", "👍🏽", "🏳️‍🌈"] {
      XCTAssertTrue(WorkspaceListIconName.isEmoji(name), name)
    }
  }

  func testTypedTextGivesItsFirstEmoji() {
    XCTAssertEqual(WorkspaceListIconName.emoji(from: "🌱 garden"), "🌱")
    XCTAssertEqual(WorkspaceListIconName.emoji(from: "garden 📚"), "📚")
    XCTAssertNil(WorkspaceListIconName.emoji(from: "garden"))
    XCTAssertNil(WorkspaceListIconName.emoji(from: "é"))
  }
}
