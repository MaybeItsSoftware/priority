import Foundation

/// The two-key shortcut state machine: `d`-then-`d` for due, `m`-then-digit-
/// then-digit for an Eisenhower coordinate, and so on.
///
/// One character of state — `quickEntry.keyBuffer` — read and written at nine
/// points scattered through `KeyboardShortcutRouter.handle`. A buffer left
/// standing swallows the next key press with no visible cause, which is the
/// failure mode this exists to make testable.
public enum ShortcutSequenceBuffer {

  /// What the router should do, alongside the buffer's new value. The buffer is
  /// always part of the answer, so no caller has to remember to clear it.
  public struct Outcome: Equatable {
    public var buffer: String
    public var effect: Effect

    public init(
      buffer: String,
      effect: Effect
    ) {
    self.buffer = buffer
    self.effect = effect
    }
  }

  public enum Effect: Equatable {
    /// Not a sequence key. Carry on to the remaining bindings.
    case pass
    /// A starter was accepted; the next key completes it.
    case awaitSecondKey
    /// `m` then a signed digit: half of a matrix coordinate, echoed to the
    /// status bar so a half-typed sequence is visible rather than silent.
    case reportMatrixUrgency(String)
    /// `m` then two signed digits: the whole coordinate.
    case applyMatrixCoordinate(urgency: Double, importance: Double)
    /// `m` then a quadrant letter. Two keystrokes for a whole-box placement,
    /// which is what makes sorting a backlog viable — the digit form is for
    /// refining one task, not for triaging two hundred.
    case applyMatrixQuadrant(MatrixQuadrant)
    /// `m00`: back to unplaced. `(0, 0)` is the store's unset sentinel, so
    /// typing it is a removal rather than a placement at the origin.
    case clearMatrixCoordinate
    /// A complete two-key sequence for the router to look up.
    case attempt(sequence: String)
    /// A sequence was pending but the second key arrived while a text field
    /// had focus. The buffer is dropped and the event is handed on unclaimed,
    /// so the character still lands in the field the user is typing into.
    case abandon
  }

  /// `starters` and `matrixStarters` are the first characters of the configured
  /// sequence bindings — derived from the bindings rather than hardcoded, so a
  /// rebound sequence keeps working.
  public static func advance(
    buffer: String,
    characters: String,
    starters: Set<String>,
    matrixStarters: Set<String>,
    isTextEntryFocused: Bool,
    shift: Bool,
    ctrl: Bool
  ) -> Outcome {
    let key = characters.lowercased()
    let pending = buffer.lowercased()

    guard !pending.isEmpty else {
      // Modifiers are excluded so `shift+d` and `ctrl+d` stay available as
      // ordinary bindings rather than being eaten as sequence starters.
      guard starters.contains(key), !shift, !ctrl, !isTextEntryFocused else {
        return Outcome(buffer: buffer, effect: .pass)
      }
      return Outcome(buffer: key, effect: .awaitSecondKey)
    }

    if !isTextEntryFocused, let matrix = matrixStep(pending, key, matrixStarters) {
      return matrix
    }

    // Any other second key ends the sequence, matched or not. Clearing the
    // buffer here — before the lookup — is what stops a failed sequence from
    // poisoning the next key press.
    //
    // A sequence that matches nothing is *not* re-tried as a single-key
    // binding: the event is handed on unclaimed either way.
    guard !isTextEntryFocused else { return Outcome(buffer: "", effect: .abandon) }
    return Outcome(buffer: "", effect: .attempt(sequence: pending + key))
  }

  /// The matrix sequence, which is the only one that can run past two keys.
  ///
  /// Three shapes share the `m` starter:
  ///
  /// - `m` + quadrant letter (`d`/`s`/`g`/`e`) places in a whole box.
  /// - `m` + signed digit + signed digit sets an exact coordinate.
  /// - `m00` clears the placement.
  ///
  /// The signs are the reason this is not simply two digit reads. Coordinates
  /// run -9...9, but the old sequence parsed one numeric character per axis and
  /// so could only ever produce positive values — meaning the keyboard could
  /// reach `Do` and nothing else, in a view whose whole point is four boxes.
  private static func matrixStep(
    _ pending: String, _ key: String, _ matrixStarters: Set<String>
  ) -> Outcome? {
    guard key.count == 1, let first = pending.first, matrixStarters.contains(String(first))
    else { return nil }
    // Everything after the starter: "", "-", "5", "-5", "5-" or "-5-".
    let rest = String(pending.dropFirst())

    switch matrixState(rest) {
    case .awaitingUrgency:
      if let quadrant = quadrantLetter(key) {
        return Outcome(buffer: "", effect: .applyMatrixQuadrant(quadrant))
      }
      if key == "-" {
        return Outcome(buffer: pending + key, effect: .awaitSecondKey)
      }
      guard key.first?.isNumber == true else { return nil }
      return Outcome(buffer: pending + key, effect: .reportMatrixUrgency(key))

    case .awaitingUrgencyDigit:
      guard key.first?.isNumber == true else { return nil }
      return Outcome(buffer: pending + key, effect: .reportMatrixUrgency("-" + key))

    case .awaitingImportance(let urgency):
      if key == "-" {
        return Outcome(buffer: pending + key, effect: .awaitSecondKey)
      }
      guard let magnitude = Double(key) else { return nil }
      return Outcome(buffer: "", effect: completion(urgency: urgency, importance: magnitude))

    case .awaitingImportanceDigit(let urgency):
      guard let magnitude = Double(key) else { return nil }
      return Outcome(buffer: "", effect: completion(urgency: urgency, importance: -magnitude))

    case .notMatrix:
      return nil
    }
  }

  /// `(0, 0)` is the unset sentinel rather than a position, so typing it means
  /// "take this off the board" — otherwise the one coordinate a user can name
  /// exactly would silently do nothing.
  private static func completion(urgency: Double, importance: Double) -> Effect {
    if urgency == 0 && importance == 0 { return .clearMatrixCoordinate }
    return .applyMatrixCoordinate(urgency: urgency, importance: importance)
  }

  private enum MatrixState {
    case awaitingUrgency
    case awaitingUrgencyDigit
    case awaitingImportance(urgency: Double)
    case awaitingImportanceDigit(urgency: Double)
    case notMatrix
  }

  private static func matrixState(_ rest: String) -> MatrixState {
    if rest.isEmpty { return .awaitingUrgency }
    if rest == "-" { return .awaitingUrgencyDigit }

    let negativeUrgency = rest.hasPrefix("-")
    let afterSign = negativeUrgency ? String(rest.dropFirst()) : rest
    guard let digit = afterSign.first, digit.isNumber, let magnitude = Double(String(digit))
    else { return .notMatrix }
    let urgency = negativeUrgency ? -magnitude : magnitude
    let tail = String(afterSign.dropFirst())

    if tail.isEmpty { return .awaitingImportance(urgency: urgency) }
    if tail == "-" { return .awaitingImportanceDigit(urgency: urgency) }
    return .notMatrix
  }

  /// `g` rather than `d` for Delegate: `d` is already Do, and the two words
  /// starting with the same letter is exactly the collision a two-key sequence
  /// cannot express.
  private static func quadrantLetter(_ key: String) -> MatrixQuadrant? {
    switch key {
    case "d": return .doNow
    case "s": return .schedule
    case "g": return .delegate
    case "e": return .eliminate
    default: return nil
    }
  }

  /// What a half-typed matrix sequence should say in the status bar.
  ///
  /// This is the discoverability half of the feature. Pressing the starter
  /// alone spells out the four quadrant letters, so the placement vocabulary is
  /// reachable by pressing one key rather than by reading the manual — and it
  /// costs no permanent chrome, because it is only on screen while a sequence
  /// is pending.
  ///
  /// Lives here, beside the parser it describes, because the status bar used to
  /// re-derive the starters and re-check the digits itself; two readings of the
  /// same buffer drift the moment either changes.
  public static func matrixHint(for buffer: String, matrixStarters: Set<String>) -> String? {
    let pending = buffer.lowercased()
    guard let first = pending.first, matrixStarters.contains(String(first)) else { return nil }

    switch matrixState(String(pending.dropFirst())) {
    case .awaitingUrgency:
      return "Matrix — d Do · s Schedule · g Delegate · e Eliminate · l Unplaced list"
        + " · or ±urgency ±importance"
    case .awaitingUrgencyDigit:
      return "Matrix: (-_, _)"
    case .awaitingImportance(let urgency):
      return "Matrix: (\(Int(urgency)), _)"
    case .awaitingImportanceDigit(let urgency):
      return "Matrix: (\(Int(urgency)), -_)"
    case .notMatrix:
      return nil
    }
  }

  /// What a pending *non*-matrix sequence should say.
  ///
  /// The matrix starter has spelled its own vocabulary out since it was built;
  /// every other one said `Sequence: d…`, which names the key you just pressed
  /// and nothing you could do with it. So the four due-and-start sequences were
  /// discoverable only by reading the manual, in an app whose whole premise is
  /// that you do not have to.
  ///
  /// Derived from the configured bindings and the actions' own titles, so a
  /// rebound sequence prints its real key and a renamed action its real name.
  ///
  /// - Parameter sequences: every two-key binding in force, paired with what it
  ///   does. Bindings that are not two keys are ignored — a hint can only offer
  ///   a second key if there is exactly one.
  public static func hint(
    forBuffer buffer: String,
    sequences: [(keys: String, label: String)]
  ) -> String? {
    let pending = buffer.lowercased()
    guard pending.count == 1, let starter = pending.first else { return nil }

    var seen: Set<String> = []
    let options =
      sequences
      .filter { $0.keys.count == 2 && $0.keys.lowercased().first == starter }
      .compactMap { sequence -> String? in
        let second = String(sequence.keys.lowercased().dropFirst()).uppercased()
        guard seen.insert(second).inserted else { return nil }
        return "\(second) \(sequence.label)"
      }
    guard !options.isEmpty else { return nil }
    return String(starter).uppercased() + " — " + options.joined(separator: " · ")
  }

  /// The first character of each configured binding. Tokens shorter than two
  /// characters are not sequences and are skipped, so a malformed binding
  /// cannot claim every press of a single letter.
  public static func starters(fromBindings tokens: [String]) -> Set<String> {
    Set(
      tokens.compactMap { token in
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count >= 2 else { return nil }
        return String(normalized.prefix(1))
      })
  }
}
