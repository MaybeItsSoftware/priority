import Foundation

/// Vim's `f` and `F`, over rows rather than characters: the next row, or the
/// previous one, whose title begins with the letter typed.
///
/// A title is read from its first letter or digit, so "— call Sam" and
/// "[x] call Sam" are both found by `c`, and the match ignores case. The walk
/// wraps, as `/` does with `wrapscan`: a list is short enough that "not
/// below you" should mean "look above", not "nothing".
public enum VimFind {
  /// The index of the row `f` (or `F`, with `forward` false) lands on, or
  /// `nil` when no row begins with the character. `current` is where the
  /// cursor is; with none, the walk starts before the first row (after the
  /// last, backwards), so the first match is a candidate.
  public static func index(
    in titles: [String], from current: Int?, character: Character, forward: Bool
  ) -> Int? {
    let count = titles.count
    guard count > 0, let target = Self.key(character) else { return nil }
    let start = current ?? (forward ? -1 : count)
    for step in 1...count {
      let index = ((start + (forward ? step : -step)) % count + count) % count
      if Self.initial(titles[index]) == target { return index }
    }
    return nil
  }

  /// The character a title is found by.
  static func initial(_ title: String) -> String? {
    title.first(where: { $0.isLetter || $0.isNumber }).flatMap(key)
  }

  private static func key(_ character: Character) -> String? {
    guard character.isLetter || character.isNumber else { return nil }
    return String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }
}
