import Foundation

/// When a in-progress rename of a daily should be written, and what to write.
///
/// This exists because of a specific bug. The settings editor bound its title
/// field straight through to the store — `set:` called `renameDaily` on every
/// keystroke — and the store trims what it is given and ignores an empty
/// result. Both of those are correct rules for a *finished* title and wrong for
/// a draft: typing a space at the end of "Morning" stored "Morning", the field
/// re-read the stored value, and the space vanished. Multi-word names could not
/// be typed at all, and clearing the field to retype snapped it back.
///
/// The fix is not to loosen the store's rules but to stop asking it about
/// keystrokes. A draft lives in the editor; this decides what happens when the
/// user is done with it.
public enum DailyTitleEdit {

  /// The title to store, or `nil` when the edit should be abandoned and the
  /// original left alone.
  ///
  /// Both `nil` cases are deliberate:
  ///
  /// - An empty draft is a slip — the user cleared the field and pressed Return,
  ///   or tabbed away mid-retype. A daily with no name is not a state worth
  ///   being able to reach, and blanking is not what "commit" means.
  /// - An unchanged draft is a no-op. Writing it anyway would take the file
  ///   lock, rewrite `dailies.json` and bump the revision — churn the whole UI
  ///   re-renders for — to store what is already there.
  public static func committed(draft: String, original: String) -> String? {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard trimmed != original else { return nil }
    return trimmed
  }
}
