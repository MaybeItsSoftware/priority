import Foundation
import TaktRustCore

/// Vim's `f` and `F`, over rows rather than characters: the next row, or the
/// previous one, whose title begins with the letter typed.
///
/// A title is read from its first letter or digit, so "— call Sam" and
/// "[x] call Sam" are both found by `c`, and the match ignores case and
/// accents. The walk wraps, as `/` does with `wrapscan`: a list is short
/// enough that "not below you" should mean "look above", not "nothing". The
/// walk is the Rust core's (`vim_find`), one call per key press.
public enum VimFind {
  /// The index of the row `f` (or `F`, with `forward` false) lands on, or
  /// `nil` when no row begins with the character. `current` is where the
  /// cursor is; with none, the walk starts before the first row (after the
  /// last, backwards), so the first match is a candidate.
  public static func index(
    in titles: [String], from current: Int?, character: Character, forward: Bool
  ) -> Int? {
    vimFind(
      titles: titles, current: current.map(Int64.init), character: String(character), forward: forward
    ).map { Int($0) }
  }
}
