import Foundation

/// What a list's icon is stored as: an SF Symbol's name, or an emoji.
///
/// Icons were symbol names only, kept per list in the preferences. An emoji is
/// kept in the same slot as the same kind of string and told apart when it is
/// drawn — a symbol's name is ASCII, an emoji never is.
public enum WorkspaceListIconName {
  /// Whether the stored icon is an emoji, to draw as text, rather than the
  /// name of a symbol.
  public static func isEmoji(_ name: String) -> Bool {
    guard name.count == 1, let character = name.first else { return false }
    return isEmojiCharacter(character)
  }

  /// The first emoji in what was typed, or nil — what the picker's emoji
  /// field makes of its text, so pasting "🌱 garden" gives 🌱.
  public static func emoji(from input: String) -> String? {
    input.first(where: isEmojiCharacter).map(String.init)
  }

  private static func isEmojiCharacter(_ character: Character) -> Bool {
    let scalars = character.unicodeScalars
    guard let first = scalars.first, !first.isASCII else { return false }
    // A scalar that is an emoji by default, or one that becomes one with a
    // variation selector or as part of a sequence (❤️, 👍🏽, 🏳️‍🌈).
    return first.properties.isEmojiPresentation || (first.properties.isEmoji && scalars.count > 1)
  }
}
