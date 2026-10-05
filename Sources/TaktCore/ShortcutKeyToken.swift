import Foundation

/// The names of keys that are spelled out in a binding token rather than
/// taken from the characters a key press carries — `space`, `enter`, `left`.
///
/// `WorkspaceCommandCatalog.key(keyCode:…)` spells a key press with these, and
/// the catalogue and a user's keymap write their keys the same way, so a key
/// the table does not name is a key no binding can match.
public enum ShortcutKeyToken {
  /// Keys whose name is spelled out rather than taken from the characters the
  /// event carries — either because they have no printable character, or
  /// because the character depends on the keyboard layout and the modifier
  /// state in ways a stored binding must not.
  public static let nameByKeyCode: [UInt16: String] = [
    18: "1",
    19: "2",
    20: "3",
    21: "4",
    23: "5",
    22: "6",
    26: "7",
    28: "8",
    25: "9",
    29: "0",
    27: "-",
    24: "=",
    // Named rather than spelled `,`, because bindings used to be stored as a
    // comma-separated list with no escape.
    43: "comma",
    49: "space",
    36: "enter",
    48: "tab",
    53: "escape",
    120: "f2",
    // Both delete keys, because the one labelled "delete" on a Mac keyboard is
    // 51 (backspace) and 117 is the forward delete hidden behind fn. 51
    // carries a non-printable character, so without an entry here it would
    // spell as that control character and match nothing.
    51: "delete",
    117: "delete",
    123: "left",
    124: "right",
    125: "down",
    126: "up",
  ]
}
