import XCTest
@testable import PriorityCore

final class DesktopShortcutSequenceTests: XCTestCase {
  func testEveryCommandRequiresBothKeys() {
    for command in DesktopShortcutSequence.commands {
      var sequence = DesktopShortcutSequence()
      XCTAssertEqual(sequence.advance(String(command.prefix(1)), at: 1), .pending)
      XCTAssertEqual(sequence.advance(String(command.suffix(1)), at: 1.2), .command(command))
      XCTAssertEqual(sequence.prefix, "")
    }
  }

  func testExpiredPrefixDoesNotExecuteACommand() {
    var sequence = DesktopShortcutSequence()
    XCTAssertEqual(sequence.advance("u", at: 1), .pending)
    XCTAssertEqual(sequence.advance("u", at: 3), .pending)
  }

  func testAnUnrelatedKeyStillReachesNavigationAndClearsThePrefix() {
    var sequence = DesktopShortcutSequence()
    _ = sequence.advance("e", at: 1)
    XCTAssertEqual(sequence.advance("j", at: 1.1), .pass)
    XCTAssertEqual(sequence.prefix, "")
  }

  func testMovingFocusCannotCompleteAnOldCommand() {
    var sequence = DesktopShortcutSequence()
    _ = sequence.advance("u", at: 1)
    sequence.reset()
    XCTAssertEqual(sequence.advance("u", at: 1.1), .pending)
  }

  func testInvalidSecondKeyCanStartANewCommand() {
    var sequence = DesktopShortcutSequence()
    _ = sequence.advance("e", at: 1)
    XCTAssertEqual(sequence.advance("d", at: 1.1), .pending)
    XCTAssertEqual(sequence.advance("d", at: 1.2), .command("dd"))
  }
}
