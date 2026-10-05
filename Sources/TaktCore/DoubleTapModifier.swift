import Foundation

/// Recognises a modifier key tapped twice on its own — Checkvist's ⇧⇧ for
/// "everything I can do", and the same gesture JetBrains and Xcode use.
///
/// A modifier produces no key-down event, so this cannot be expressed as a
/// binding: it is a state machine over flag changes. Which is also why the
/// contamination rules matter more than the timing. Shift is held for every
/// capital letter in the app, so a detector that only watched flags would fire
/// on ordinary typing; a tap only counts when Shift went down and came back up
/// with nothing pressed in between and no other modifier alongside it.
public struct DoubleTapModifier: Sendable {

  /// How long the second tap has to arrive. 0.4s is the usual double-click
  /// window: long enough not to demand a drum roll, short enough that two
  /// unrelated Shift presses a second apart are not one gesture.
  public let window: TimeInterval

  private var isDown = false
  /// Something happened during this press that makes it a chord rather than a
  /// tap — another modifier, or any ordinary key.
  private var isChord = false
  private var lastTapEnded: TimeInterval?

  public init(window: TimeInterval = 0.4) {
    self.window = window
  }

  /// The watched modifier went down or came up.
  ///
  /// - Returns: true when this release completes a second clean tap, at which
  ///   point the detector is armed again from scratch — so a third press does
  ///   not fire a second time off the back of the same gesture.
  public mutating func modifierChanged(
    isDown newIsDown: Bool,
    otherModifiersHeld: Bool,
    at time: TimeInterval
  ) -> Bool {
    guard newIsDown != isDown else {
      // A flags change that did not move the watched key — some other modifier
      // going down while this one is held. That makes a chord of it.
      if isDown, otherModifiersHeld { isChord = true }
      return false
    }
    isDown = newIsDown

    if newIsDown {
      isChord = otherModifiersHeld
      return false
    }

    defer { isChord = false }
    guard !isChord, !otherModifiersHeld else {
      lastTapEnded = nil
      return false
    }

    if let previous = lastTapEnded, time - previous <= window {
      lastTapEnded = nil
      return true
    }
    lastTapEnded = time
    return false
  }

  /// An ordinary key was pressed. Anything typed while the modifier is held
  /// makes this a chord, and anything typed between the two taps means the
  /// user was working rather than gesturing.
  public mutating func keyPressed() {
    if isDown { isChord = true }
    lastTapEnded = nil
  }
}
