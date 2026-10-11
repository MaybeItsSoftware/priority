import Foundation

extension WorkspaceCommand {
  /// The one key a context menu shows beside this command, as a raw token —
  /// or nil when none of its keys can be drawn as a menu's key equivalent.
  ///
  /// A context menu is opened on a row of one surface, so that surface's own
  /// keys come first, and of those the plain ones: Zed's project panel menu
  /// says `%` and `d` beside New File and New Directory, because those are the
  /// keys the panel answers to, not the chords that also reach them from
  /// anywhere. After that, the first key in the order the row lists them that
  /// a menu can draw at all. Two-key sequences (`oo`, `gh`) cannot be, so
  /// List Settings shows its chord instead.
  ///
  /// Read from the catalogue with the keymap in force, so a rebound key is the
  /// one the menu shows.
  public func contextMenuKey(on surface: WorkspaceCommandSurface) -> String? {
    let own = surfaceKeys[surface] ?? []
    if let plain = own.first(where: { Self.isMenuDrawable($0) && !Self.hasCommandModifier($0) }) {
      return plain
    }
    return (own + keys).first(where: Self.isMenuDrawable)
  }

  /// `contextMenuKey(on:)` as a menu item takes it: the key and its
  /// modifiers, with a shifted digit or punctuation key written as the
  /// character it types — `shift+5` is `%`, as Zed's menu shows it, not ⇧5.
  public func contextMenuKeyEquivalent(on surface: WorkspaceCommandSurface) -> MenuKeyEquivalent? {
    guard let token = contextMenuKey(on: surface) else { return nil }
    var parts = Self.menuTokenParts(token)
    guard let key = parts.popLast() else { return nil }
    if parts == ["shift"], let shifted = Self.shiftedCharacters[key] {
      return MenuKeyEquivalent(key: shifted, modifiers: [])
    }
    return MenuKeyEquivalent(key: key, modifiers: parts)
  }

  /// A key as a menu item draws it: one character or a named key
  /// (`delete`, `f2`, `left`), and the modifiers held with it.
  public struct MenuKeyEquivalent: Equatable, Sendable {
    public let key: String
    public let modifiers: [String]

    public init(key: String, modifiers: [String]) {
      self.key = key
      self.modifiers = modifiers
    }
  }

  /// What shift types on the keys that are not letters, on the US layout the
  /// binding format is written against.
  static let shiftedCharacters: [String: String] = [
    "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
    "-": "_", "=": "+", "[": "{", "]": "}", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?",
    "`": "~", "\\": "|",
  ]

  /// Whether a token names one key, possibly modified — what a menu item can
  /// draw — rather than a sequence of keys.
  public static func isMenuDrawable(_ token: String) -> Bool {
    let parts = menuTokenParts(token)
    guard let key = parts.last, !key.isEmpty else { return false }
    let modifiers = parts.dropLast()
    guard modifiers.allSatisfy(knownModifiers.contains) else { return false }
    return key.count == 1 || namedMenuKeys.contains(key)
  }

  private static func hasCommandModifier(_ token: String) -> Bool {
    menuTokenParts(token).dropLast().contains { $0 == "cmd" || $0 == "ctrl" || $0 == "option" }
  }

  /// `cmd+shift+=` and `shift++` both end in a key that is itself a `+`, so a
  /// plain split would lose it.
  static func menuTokenParts(_ token: String) -> [String] {
    if token == "+" { return ["+"] }
    if token.hasSuffix("++") {
      return token.dropLast(2).split(separator: "+").map(String.init) + ["+"]
    }
    return token.split(separator: "+").map(String.init)
  }

  static let knownModifiers: Set<String> = ["cmd", "shift", "option", "ctrl"]

  /// Named keys a menu item can show: the arrows and editing keys, and the
  /// function row.
  static let namedMenuKeys: Set<String> = Set(
    ["up", "down", "left", "right", "delete", "enter", "tab", "space", "escape", "comma",
     "home", "end", "pageup", "pagedown"]
      + (1...12).map { "f\($0)" })
}
