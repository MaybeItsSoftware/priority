import Foundation

/// Choosing and ordering the rows a palette shows.
///
/// Kept out of the view because the interesting part is not the list — it is
/// the ranking, and a ranking you cannot write a test against is a ranking
/// that quietly stops being right.
public enum WorkspaceCommandQuery {

  /// A command plus why it ranked where it did, so the palette can show the
  /// surface badge without recomputing anything.
  public struct Match: Identifiable, Sendable, Equatable {
    public let command: WorkspaceCommand
    public let score: Int
    public var id: WorkspaceCommandID { command.id }
  }

  /// - Parameters:
  ///   - query: what has been typed. Empty means "show me everything", which
  ///     is the state the palette opens in and the state that answers the
  ///     question "what can I press here".
  ///   - surface: what is on screen. Commands belonging to it sort above the
  ///     ones that apply anywhere, and commands belonging to some *other*
  ///     surface sort last rather than vanishing — a key you cannot press
  ///     right now is still a key worth knowing about.
  public static func matches(
    query: String,
    surface: WorkspaceCommandSurface,
    in catalogue: [WorkspaceCommand] = WorkspaceCommandCatalog.all
  ) -> [Match] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    let scored: [Match] = catalogue.compactMap { command in
      let relevance = surfaceScore(command.surface, on: surface)
      guard needle.isEmpty else {
        guard let text = textScore(needle, in: command) else { return nil }
        return Match(command: command, score: text + relevance)
      }
      return Match(command: command, score: relevance)
    }

    // Stable within a score: `all` is already ordered most-pressed-first, and
    // re-sorting equal rows alphabetically would scatter the groups.
    return stableSortedByScore(scored)
  }

  /// Higher is nearer the top.
  private static func surfaceScore(
    _ commandSurface: WorkspaceCommandSurface,
    on surface: WorkspaceCommandSurface
  ) -> Int {
    if commandSurface == surface { return 200 }
    if commandSurface == .anywhere { return 100 }
    return 0
  }

  /// `nil` when the row does not match at all.
  private static func textScore(_ needle: String, in command: WorkspaceCommand) -> Int? {
    let title = command.title.lowercased()
    if title.hasPrefix(needle) { return 600 }
    // A word-start match — "col" finding "Add a board column" — beats a match
    // buried mid-word, which is usually a coincidence.
    if title.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) { return 450 }
    if title.contains(needle) { return 300 }

    // Typing the keys themselves is a real way to ask what a shortcut does.
    if command.displayKeys.contains(where: { $0.lowercased().contains(needle) }) { return 250 }
    if command.keys.contains(where: { $0.lowercased().contains(needle) }) { return 250 }

    if command.searchText.lowercased().contains(needle) { return 150 }
    if isSubsequence(needle, of: title) { return 50 }
    return nil
  }

  /// "atk" matching "Add a task" — the usual palette affordance, and the
  /// reason a two-word command can be reached in three keystrokes.
  static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
    var remaining = Substring(needle)
    for character in haystack where character == remaining.first {
      remaining = remaining.dropFirst()
      if remaining.isEmpty { return true }
    }
    return remaining.isEmpty
  }

  private static func stableSortedByScore(_ matches: [Match]) -> [Match] {
    matches.enumerated()
      .sorted { left, right in
        if left.element.score != right.element.score {
          return left.element.score > right.element.score
        }
        return left.offset < right.offset
      }
      .map(\.element)
  }
}
