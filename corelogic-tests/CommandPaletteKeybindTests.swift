import XCTest

@testable import PriorityCore

/// The shortcut a palette row prints is a claim that pressing it runs that row.
final class CommandPaletteKeybindTests: XCTestCase {

  /// Nine rows used to print `dd` or `ds` — the sequences that *open* the due
  /// and start lists rather than pick anything from them. One key against nine
  /// commands reads as a collision, and a reader has no way to tell which of
  /// the nine it really means.
  func testNoShortcutIsClaimedByTwoCommands() {
    var owners: [String: [String]] = [:]
    for suggestion in CommandEngine.suggestions {
      guard let keybind = suggestion.keybind else { continue }
      owners[keybind, default: []].append(suggestion.label)
    }

    let shared = owners.filter { $0.value.count > 1 }
    XCTAssertTrue(
      shared.isEmpty,
      "shortcuts claimed by more than one row: \(shared)")
  }

  /// A sequence starter on its own is not a shortcut for anything, with one
  /// exception: `m`, which the digits complete into the very command it sits on.
  func testAPrintedShortcutIsNotABareSequenceStarter() {
    let starters = Set(
      ConfigurableShortcutAction.twoKeySequenceActions
        .flatMap { $0.defaultBinding.split(separator: ",") }
        .compactMap { $0.trimmingCharacters(in: .whitespaces).first.map(String.init) })

    for suggestion in CommandEngine.suggestions {
      guard let keybind = suggestion.keybind, keybind.count == 1 else { continue }
      XCTAssertFalse(
        starters.contains(keybind.lowercased()) && suggestion.command != "matrix ",
        "\(suggestion.label) prints the bare starter \(keybind)")
    }
  }
}
