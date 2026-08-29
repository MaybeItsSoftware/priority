import XCTest

@testable import PriorityCore

/// Shift is held for every capital letter typed into this app, so the whole
/// difficulty of ⇧⇧ is telling a gesture from ordinary work.
final class DoubleTapModifierTests: XCTestCase {

  private func tap(
    _ detector: inout DoubleTapModifier, at time: TimeInterval, other: Bool = false
  ) -> Bool {
    _ = detector.modifierChanged(isDown: true, otherModifiersHeld: other, at: time)
    return detector.modifierChanged(isDown: false, otherModifiersHeld: other, at: time + 0.05)
  }

  func testTwoCleanTapsInsideTheWindowFire() {
    var detector = DoubleTapModifier()
    XCTAssertFalse(tap(&detector, at: 0))
    XCTAssertTrue(tap(&detector, at: 0.2))
  }

  func testASecondTapAfterTheWindowIsJustAnotherFirstTap() {
    var detector = DoubleTapModifier()
    XCTAssertFalse(tap(&detector, at: 0))
    XCTAssertFalse(tap(&detector, at: 1.0))
    // …and that late tap arms the next one.
    XCTAssertTrue(tap(&detector, at: 1.2))
  }

  /// The one that would make the feature unusable: typing capitals.
  func testShiftHeldForACapitalLetterIsNotATap() {
    var detector = DoubleTapModifier()
    _ = detector.modifierChanged(isDown: true, otherModifiersHeld: false, at: 0)
    detector.keyPressed()
    XCTAssertFalse(detector.modifierChanged(isDown: false, otherModifiersHeld: false, at: 0.05))
    XCTAssertFalse(tap(&detector, at: 0.1))
  }

  func testTypingBetweenTheTapsBreaksTheGesture() {
    var detector = DoubleTapModifier()
    XCTAssertFalse(tap(&detector, at: 0))
    detector.keyPressed()
    XCTAssertFalse(tap(&detector, at: 0.2))
  }

  func testAModifierChordIsNotATap() {
    var detector = DoubleTapModifier()
    XCTAssertFalse(tap(&detector, at: 0, other: true))
    XCTAssertFalse(tap(&detector, at: 0.2, other: true))
  }

  /// Shift down, then Command down on top of it, then both up. The release is
  /// clean by then, so only the record of the chord stops it counting.
  func testAnotherModifierArrivingMidPressPoisonsTheTap() {
    var detector = DoubleTapModifier()
    _ = detector.modifierChanged(isDown: true, otherModifiersHeld: false, at: 0)
    _ = detector.modifierChanged(isDown: true, otherModifiersHeld: true, at: 0.05)
    XCTAssertFalse(detector.modifierChanged(isDown: false, otherModifiersHeld: false, at: 0.1))
    XCTAssertFalse(tap(&detector, at: 0.15))
  }

  /// Three taps are one gesture and then a fresh first tap, not two gestures
  /// overlapping.
  func testFiringRearmsFromScratch() {
    var detector = DoubleTapModifier()
    XCTAssertFalse(tap(&detector, at: 0))
    XCTAssertTrue(tap(&detector, at: 0.2))
    XCTAssertFalse(tap(&detector, at: 0.4))
    XCTAssertTrue(tap(&detector, at: 0.6))
  }
}
