import Foundation

/// A binding token as it is read on a Mac keyboard — `cmd+shift+k` as `⇧⌘K`,
/// `dd` as `D D`.
///
/// This used to be a whole keyboard reference built from the old remapping
/// stack's actions. The workspace's reference is now drawn from
/// `WorkspaceCommandCatalog`, so all that is left here is the rendering every
/// key cap shares.
public enum ShortcutReference {

  /// Splits a binding on its commas and renders each alternative.
  public static func displayKeys(forBinding binding: String) -> [String] {
    binding
      .split(separator: ",")
      .map { display(token: String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
      .filter { !$0.isEmpty }
  }

  /// One binding token as it should be read on a Mac keyboard.
  ///
  /// Two-key sequences are rendered spaced — `d d`, not `dd` — because the
  /// unspaced form reads as one chord and is the reason people press `d` and
  /// wonder why nothing happened.
  public static func display(token rawToken: String) -> String {
    let token = rawToken.lowercased()
    guard !token.isEmpty else { return "" }

    if !token.contains("+"), token.count > 1, let named = keyName[token] {
      return named
    }
    // A modifier-free multi-character token is a sequence, not a key name.
    if !token.contains("+"), token.count > 1 {
      return token.map(String.init).map { $0.uppercased() }.joined(separator: " ")
    }

    let parts = token.split(separator: "+").map(String.init)
    guard let base = parts.last else { return "" }
    let symbols = parts.dropLast().map { modifierSymbol[$0] ?? $0 }.joined()
    return symbols + (keyName[base] ?? base.uppercased())
  }

  /// In the order macOS writes them, which is not the order the binding format
  /// stores them in.
  private static let modifierSymbol: [String: String] = [
    "ctrl": "⌃", "option": "⌥", "shift": "⇧", "cmd": "⌘",
  ]

  private static let keyName: [String: String] = [
    "up": "↑", "down": "↓", "left": "←", "right": "→",
    "enter": "↩", "tab": "⇥", "escape": "⎋", "delete": "⌫",
    "space": "Space", "comma": ",", "f2": "F2",
    "home": "Home", "end": "End", "pageup": "PgUp", "pagedown": "PgDn",
  ]
}
