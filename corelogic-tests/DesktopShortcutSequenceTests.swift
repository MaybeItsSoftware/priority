import XCTest
@testable import TaktCore

final class DesktopShortcutSequenceTests: XCTestCase {
  private let outline = WorkspaceCommandCatalog.sequences(on: .outline)

  func testEveryCommandRequiresBothKeys() {
    for command in outline {
      var sequence = DesktopShortcutSequence()
      XCTAssertEqual(sequence.advance(String(command.prefix(1)), at: 1, sequences: outline), .pending)
      XCTAssertEqual(
        sequence.advance(String(command.suffix(1)), at: 1.2, sequences: outline), .command(command))
      XCTAssertEqual(sequence.prefix, "")
    }
  }

  /// The bug this type was rewritten for: `x` began `xx`, so it was held, and
  /// nothing ever ran it on its own.
  func testAHeldKeyRunsOnItsOwnWhenTheNextKeyIsNotItsSecondLetter() {
    var sequence = DesktopShortcutSequence()
    XCTAssertEqual(sequence.advance("x", at: 1, sequences: outline), .pending)
    XCTAssertEqual(sequence.advance("j", at: 1.1, sequences: outline), .flush("x"))
    XCTAssertEqual(sequence.prefix, "")
  }

  func testAHeldKeyRunsOnItsOwnWhenTheHoldTimesOut() {
    var sequence = DesktopShortcutSequence()
    XCTAssertEqual(sequence.advance("x", at: 1, sequences: outline), .pending)
    XCTAssertEqual(sequence.expire(heldAt: 1), "x")
    XCTAssertEqual(sequence.prefix, "")
    XCTAssertNil(sequence.expire(heldAt: 1), "a hold releases once")
  }

  /// A timer armed for a hold that a key already flushed must not cut the
  /// next hold short.
  func testAnOldTimerCannotReleaseANewerHold() {
    var sequence = DesktopShortcutSequence()
    _ = sequence.advance("x", at: 1, sequences: outline)
    XCTAssertEqual(sequence.advance("d", at: 1.5, sequences: outline), .flushAndHold("x"))
    XCTAssertNil(sequence.expire(heldAt: 1))
    XCTAssertEqual(sequence.expire(heldAt: 1.5), "d")
  }

  /// A second letter after the hold has lapsed is a new key, not a sequence —
  /// and the lapsed key still runs.
  func testAnExpiredPrefixFlushesRatherThanCompleting() {
    var sequence = DesktopShortcutSequence()
    XCTAssertEqual(sequence.advance("u", at: 1, sequences: outline), .pending)
    XCTAssertEqual(sequence.advance("u", at: 3, sequences: outline), .flushAndHold("u"))
  }

  func testAKeyThatStartsNothingPassesStraightThrough() {
    var sequence = DesktopShortcutSequence()
    XCTAssertEqual(sequence.advance("j", at: 1, sequences: outline), .pass)
    XCTAssertEqual(sequence.advance("down", at: 1.1, sequences: outline), .pass)
  }

  func testMovingFocusDropsTheHeldKeyWithoutRunningIt() {
    var sequence = DesktopShortcutSequence()
    _ = sequence.advance("u", at: 1, sequences: outline)
    sequence.reset()
    XCTAssertNil(sequence.flush())
    XCTAssertEqual(sequence.advance("u", at: 1.1, sequences: outline), .pending)
  }

  func testInvalidSecondKeyCanStartANewCommand() {
    var sequence = DesktopShortcutSequence()
    _ = sequence.advance("e", at: 1, sequences: outline)
    XCTAssertEqual(sequence.advance("d", at: 1.1, sequences: outline), .flushAndHold("e"))
    XCTAssertEqual(sequence.advance("d", at: 1.2, sequences: outline), .command("dd"))
  }

  /// Where no sequence begins with a key, it runs at once. On the timeline
  /// `x` means nothing and nothing there starts with it, so it must not wait
  /// out the timeout the way it does on the outline, where `xx` exists.
  func testAKeyIsOnlyHeldWhereASequenceBeginsWithIt() {
    var timeline = DesktopShortcutSequence()
    XCTAssertEqual(
      timeline.advance("x", at: 1, sequences: WorkspaceCommandCatalog.sequences(on: .timeline)), .pass)
    var list = DesktopShortcutSequence()
    XCTAssertEqual(list.advance("x", at: 1, sequences: outline), .pending)
  }

  /// `l` and `h` open and leave a task's subtasks, the keys you navigate by;
  /// Checkvist's `ll`, `hc` and `hh` moved off them so they never wait.
  func testTheNavigationLettersAreNeverHeldOnTheTaskPanes() {
    for surface in [WorkspaceCommandSurface.outline, .board, .today, .matrix, .sidebar] {
      let sequences = WorkspaceCommandCatalog.sequences(on: surface)
      for key in ["h", "j", "k", "l"] {
        var sequence = DesktopShortcutSequence()
        XCTAssertEqual(sequence.advance(key, at: 1, sequences: sequences), .pass, "\(key) on \(surface)")
      }
    }
  }
}
