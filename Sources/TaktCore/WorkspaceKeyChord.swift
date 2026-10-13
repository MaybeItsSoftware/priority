import Foundation
import TaktRustCore

/// A catalogue key taken apart for a toolkit's own key type — the iPhone's
/// `KeyEquivalent`, Android's Compose `Key` — by the core's
/// `keyboard_chord`. Read when a screen builds its shortcuts, never per key
/// press.
public struct WorkspaceKeyChord: Equatable, Sendable {
  public let cmd: Bool
  public let ctrl: Bool
  public let option: Bool
  public let shift: Bool
  /// A character, or one of the catalogue's named keys (`up`, `enter`, …).
  public let key: String
  /// No modifier on a key that types or edits text: a text field's, not a
  /// shortcut's.
  public let belongsToTyping: Bool

  /// Nil for a two-letter sequence, which no single key press is.
  public init?(_ key: String) {
    guard let chord = keyboardChord(key: key) else { return nil }
    cmd = chord.cmd
    ctrl = chord.ctrl
    option = chord.option
    shift = chord.shift
    self.key = chord.key
    belongsToTyping = chord.belongsToTyping
  }
}
