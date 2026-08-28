import XCTest

@testable import PriorityCore

/// The two-key shortcut state machine. It is one character of state read and
/// written at nine points inside `KeyboardShortcutRouter.handle`; a buffer left
/// standing swallows the next key press with no visible cause.
final class ShortcutSequenceBufferTests: XCTestCase {

  private let starters: Set<String> = ["d", "t", "m"]
  private let matrixStarters: Set<String> = ["m"]

  private func advance(
    buffer: String,
    _ characters: String,
    focused: Bool = false,
    shift: Bool = false,
    ctrl: Bool = false
  ) -> ShortcutSequenceBuffer.Outcome {
    ShortcutSequenceBuffer.advance(
      buffer: buffer, characters: characters, starters: starters,
      matrixStarters: matrixStarters, isTextEntryFocused: focused, shift: shift, ctrl: ctrl)
  }

  // MARK: - Starting

  func testAStarterKeyOpensASequence() {
    XCTAssertEqual(
      advance(buffer: "", "d"),
      .init(buffer: "d", effect: .awaitSecondKey))
  }

  func testANonStarterIsLeftForTheOtherBindings() {
    XCTAssertEqual(advance(buffer: "", "q"), .init(buffer: "", effect: .pass))
  }

  func testStartersAreCaseInsensitiveButBufferLowercased() {
    XCTAssertEqual(advance(buffer: "", "D"), .init(buffer: "d", effect: .awaitSecondKey))
  }

  /// `shift+d` and `ctrl+d` have to stay available as ordinary bindings, so a
  /// modified starter is not a starter.
  func testAModifiedStarterIsNotASequence() {
    XCTAssertEqual(advance(buffer: "", "d", shift: true).effect, .pass)
    XCTAssertEqual(advance(buffer: "", "d", ctrl: true).effect, .pass)
  }

  func testNoSequenceStartsWhileTypingIntoAField() {
    XCTAssertEqual(advance(buffer: "", "d", focused: true).effect, .pass)
  }

  // MARK: - Completing

  func testASecondKeyCompletesTheSequenceAndClearsTheBuffer() {
    XCTAssertEqual(
      advance(buffer: "d", "d"),
      .init(buffer: "", effect: .attempt(sequence: "dd")))
  }

  /// The buffer is cleared *before* the lookup, so a sequence that matches
  /// nothing cannot poison the next key press.
  func testAnUnmatchedSequenceStillClearsTheBuffer() {
    XCTAssertEqual(advance(buffer: "d", "z").buffer, "")
  }

  /// Typing resumes mid-sequence: the pending buffer is dropped and the
  /// character is handed on so it lands in the field.
  func testAPendingSequenceIsAbandonedWhenAFieldTakesFocus() {
    XCTAssertEqual(
      advance(buffer: "d", "x", focused: true),
      .init(buffer: "", effect: .abandon))
  }

  // MARK: - The matrix coordinate

  func testTheMatrixStarterFollowedByADigitAdvancesRatherThanCompletes() {
    XCTAssertEqual(
      advance(buffer: "m", "3"),
      .init(buffer: "m3", effect: .reportMatrixUrgency("3")))
  }

  func testASecondDigitCompletesTheCoordinate() {
    XCTAssertEqual(
      advance(buffer: "m3", "7"),
      .init(buffer: "", effect: .applyMatrixCoordinate(urgency: 3, importance: 7)))
  }

  /// `(0, 0)` is the store's unset sentinel, not a position on the board, so
  /// the one coordinate a user can name exactly has to mean removal. Typing it
  /// used to produce a placement the store then silently discarded on save.
  func testTypingTheOriginClearsThePlacement() {
    XCTAssertEqual(advance(buffer: "m0", "0").effect, .clearMatrixCoordinate)
  }

  // MARK: - Signs

  /// The gap this closes. Coordinates run -9...9, but the sequence read one
  /// numeric character per axis, so every keyboard placement was positive on
  /// both — `Do` was reachable and the other three boxes were not.
  func testAMinusBeforeTheFirstDigitMakesUrgencyNegative() {
    XCTAssertEqual(
      advance(buffer: "m", "-"),
      .init(buffer: "m-", effect: .awaitSecondKey))
    XCTAssertEqual(
      advance(buffer: "m-", "3"),
      .init(buffer: "m-3", effect: .reportMatrixUrgency("-3")))
    XCTAssertEqual(
      advance(buffer: "m-3", "5").effect,
      .applyMatrixCoordinate(urgency: -3, importance: 5))
  }

  func testAMinusBeforeTheSecondDigitMakesImportanceNegative() {
    XCTAssertEqual(
      advance(buffer: "m3", "-"),
      .init(buffer: "m3-", effect: .awaitSecondKey))
    XCTAssertEqual(
      advance(buffer: "m3-", "5").effect,
      .applyMatrixCoordinate(urgency: 3, importance: -5))
  }

  func testBothAxesCanBeNegative() {
    XCTAssertEqual(
      advance(buffer: "m-4-", "4").effect,
      .applyMatrixCoordinate(urgency: -4, importance: -4))
  }

  /// Each of the four boxes is reachable, which is the actual acceptance
  /// criterion — the signs are only the means.
  func testEveryQuadrantIsReachableByCoordinate() {
    let placements: [(String, String, MatrixQuadrant)] = [
      ("m5", "5", .doNow),
      ("m-5", "5", .schedule),
      ("m5-", "5", .delegate),
      ("m-5-", "5", .eliminate),
    ]
    for (buffer, key, expected) in placements {
      guard case .applyMatrixCoordinate(let urgency, let importance) =
        advance(buffer: buffer, key).effect
      else { return XCTFail("\(buffer)\(key) did not produce a coordinate") }
      XCTAssertEqual(
        MatrixGeometry.quadrant(urgency: urgency, importance: importance), expected)
    }
  }

  func testALoneMinusThatIsNeverCompletedIsNotACoordinate() {
    XCTAssertNil(advance(buffer: "m-", "t").effect.matrixCoordinate)
  }

  // MARK: - Quadrant letters

  /// Two keystrokes per task is what makes triaging a backlog viable; four
  /// digits with signs is for refining one.
  func testAQuadrantLetterPlacesInOneGesture() {
    XCTAssertEqual(
      advance(buffer: "m", "d"),
      .init(buffer: "", effect: .applyMatrixQuadrant(.doNow)))
    XCTAssertEqual(advance(buffer: "m", "s").effect, .applyMatrixQuadrant(.schedule))
    XCTAssertEqual(advance(buffer: "m", "g").effect, .applyMatrixQuadrant(.delegate))
    XCTAssertEqual(advance(buffer: "m", "e").effect, .applyMatrixQuadrant(.eliminate))
  }

  /// A quadrant letter always clears the buffer, so a mistyped one cannot
  /// swallow the following key.
  func testAQuadrantLetterClearsTheBuffer() {
    XCTAssertEqual(advance(buffer: "m", "d").buffer, "")
  }

  /// The letters only mean quadrants immediately after the starter. Once a
  /// digit has been taken they are not coordinates and the sequence ends.
  func testAQuadrantLetterAfterADigitIsNotAPlacement() {
    XCTAssertEqual(
      advance(buffer: "m3", "d"),
      .init(buffer: "", effect: .attempt(sequence: "m3d")))
  }

  /// A non-digit, non-quadrant letter after the matrix starter is an ordinary
  /// two-key sequence, not a broken coordinate.
  func testANonDigitAfterTheMatrixStarterCompletesNormally() {
    XCTAssertEqual(
      advance(buffer: "m", "t"),
      .init(buffer: "", effect: .attempt(sequence: "mt")))
  }

  func testANonMatrixStarterFollowedByADigitIsAnOrdinarySequence() {
    XCTAssertEqual(
      advance(buffer: "d", "3"),
      .init(buffer: "", effect: .attempt(sequence: "d3")))
  }

  /// The three-key form is unavailable while typing, so the coordinate is not
  /// half-applied from digits meant for a text field.
  func testTheCoordinateDoesNotAdvanceWhileTypingIntoAField() {
    XCTAssertEqual(advance(buffer: "m", "3", focused: true).effect, .abandon)
  }

  // MARK: - Deriving starters from bindings

  func testStartersAreTheFirstCharacterOfEachBinding() {
    XCTAssertEqual(
      ShortcutSequenceBuffer.starters(fromBindings: ["dd", "dt", "gc"]), ["d", "g"])
  }

  /// A one-character token is not a sequence. Treating it as one would let a
  /// malformed binding claim every press of that letter.
  func testSingleCharacterBindingsAreNotStarters() {
    XCTAssertEqual(ShortcutSequenceBuffer.starters(fromBindings: ["d", ""]), [])
  }

  func testBindingsAreTrimmedAndLowercasedBeforeUse() {
    XCTAssertEqual(ShortcutSequenceBuffer.starters(fromBindings: ["  DD "]), ["d"])
  }

}

extension ShortcutSequenceBuffer.Effect {
  /// The coordinate this effect carries, if it carries one. Only used to
  /// assert the *absence* of one, where a full pattern match reads as noise.
  var matrixCoordinate: (urgency: Double, importance: Double)? {
    guard case .applyMatrixCoordinate(let urgency, let importance) = self else { return nil }
    return (urgency, importance)
  }
}

/// The status bar used to re-derive starters and re-check digits itself, so the
/// hint and the parser were two readings of one buffer. These pin them together.
final class ShortcutSequenceBufferHintTests: XCTestCase {

  private func hint(_ buffer: String) -> String? {
    ShortcutSequenceBuffer.matrixHint(for: buffer, matrixStarters: ["m"])
  }

  /// One keypress spells out the whole placement vocabulary, which is the
  /// alternative to documenting it in permanent chrome.
  func testTheStarterAloneNamesEveryQuadrantLetter() {
    let text = hint("m")
    XCTAssertNotNil(text)
    for quadrant in MatrixQuadrant.allCases {
      XCTAssertTrue(
        text!.contains(quadrant.title),
        "the hint should name \(quadrant.title)")
    }
  }

  /// The drawer is off by default, so the keypress that opens it has to be
  /// reachable from the same hint the placement letters are — there is no
  /// permanent chrome naming it.
  func testTheStarterAlsoNamesTheUnplacedList() {
    XCTAssertEqual(hint("m")?.contains("Unplaced"), true)
  }

  /// `l` is not a quadrant letter, a sign or a digit, so the matrix parser has
  /// to decline it and let the ordinary two-key lookup claim `ml`.
  func testTheUnplacedToggleFallsThroughToTheSequenceLookup() {
    let outcome = ShortcutSequenceBuffer.advance(
      buffer: "m", characters: "l", starters: ["m"], matrixStarters: ["m"],
      isTextEntryFocused: false, shift: false, ctrl: false)
    XCTAssertEqual(outcome.effect, .attempt(sequence: "ml"))
    XCTAssertEqual(outcome.buffer, "")
  }

  func testAPendingCoordinateShowsWhatHasBeenTakenSoFar() {
    XCTAssertEqual(hint("m5"), "Matrix: (5, _)")
    XCTAssertEqual(hint("m-5"), "Matrix: (-5, _)")
    XCTAssertEqual(hint("m5-"), "Matrix: (5, -_)")
    XCTAssertEqual(hint("m-"), "Matrix: (-_, _)")
  }

  func testABufferForAnotherSequenceHasNoMatrixHint() {
    XCTAssertNil(hint("d"))
    XCTAssertNil(hint(""))
  }
}
