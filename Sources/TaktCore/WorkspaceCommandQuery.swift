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

    public init(command: WorkspaceCommand, score: Int) {
      self.command = command
      self.score = score
    }
  }

  /// How many recently run commands are remembered, and boosted.
  public static let recentLimit = 20

  /// - Parameters:
  ///   - query: what has been typed. Empty means "show me everything", which
  ///     is the state the palette opens in and the state that answers the
  ///     question "what can I press here".
  ///   - surface: what is on screen. Commands belonging to it sort above the
  ///     ones that apply anywhere, and commands belonging to some *other*
  ///     surface sort last rather than vanishing — a key you cannot press
  ///     right now is still a key worth knowing about.
  ///   - recents: commands run from the palette, most recent first. They rise,
  ///     the most recent furthest, so the command you ran a moment ago is one
  ///     Return away when you open the palette to run it again.
  public static func matches(
    query: String,
    surface: WorkspaceCommandSurface,
    recents: [WorkspaceCommandID] = [],
    in catalogue: [WorkspaceCommand] = WorkspaceCommandCatalog.all
  ) -> [Match] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    var recency: [WorkspaceCommandID: Int] = [:]
    for (index, id) in recents.prefix(recentLimit).enumerated() where recency[id] == nil {
      recency[id] = (recentLimit - index) * recentStep
    }

    let scored: [Match] = catalogue.compactMap { command in
      let relevance = surfaceScore(command.surface, on: surface) + (recency[command.id] ?? 0)
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

  /// `recents` with `id` moved to the front and the list capped — what the
  /// app stores after running a command from the palette.
  public static func recording(
    _ id: WorkspaceCommandID,
    in recents: [WorkspaceCommandID]
  ) -> [WorkspaceCommandID] {
    Array(([id] + recents.filter { $0 != id }).prefix(recentLimit))
  }

  /// The most recent command is worth a surface's worth of rank and a bit
  /// more; the twentieth, a nudge. Enough to reorder close matches, not to
  /// lift a poor match over a good one.
  private static let recentStep = 12

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
    // Typing the key itself is a real way to ask what a shortcut does, and
    // typing it exactly is as specific as a query gets.
    let tokens = command.allKeys.map { $0.lowercased() }
    let rendered = command.displayKeys.map { $0.lowercased() }
    if tokens.contains(needle) || rendered.contains(needle) { return 1_000 }

    var best: Int?
    if let fuzzy = fuzzyScore(needle, in: command.title) {
      // Shorter titles win a tie: "add" means "Add a task" before it means
      // "Add a task above".
      best = 400 + fuzzy - command.title.count / 4
    }
    if needle.count > 1,
      tokens.contains(where: { $0.contains(needle) }) || rendered.contains(where: { $0.contains(needle) })
    {
      best = max(best ?? 0, 350)
    }
    // The group and the note are there so "quadrant" finds the matrix row
    // whose title does not use the word — worth less than the title itself.
    let rest = [command.group, command.note ?? ""].joined(separator: " ")
    if let fuzzy = fuzzyScore(needle, in: rest) {
      best = max(best ?? 0, 100 + fuzzy / 2)
    }
    return best
  }

  // MARK: - Fuzzy matching

  /// How well `needle` matches `haystack` as a subsequence, or `nil` when it
  /// does not.
  ///
  /// Each matched character scores; one that starts a word, or the title,
  /// scores more; one that follows the previous match directly scores more
  /// again; and every character skipped between two matches costs a little.
  /// The best alignment wins, so "due" in "Clear the due date" is read at the
  /// word "due" rather than at the `d` of "date". Spaces in the query are
  /// dropped — the word-start bonus is what they were asking for.
  public static func fuzzyScore(_ needle: String, in haystack: String) -> Int? {
    let query = Array(needle.lowercased().filter { !$0.isWhitespace })
    let text = Array(haystack.lowercased())
    guard !query.isEmpty else { return 0 }
    guard query.count <= text.count else { return nil }

    let unreachable = Int.min / 4
    func charScore(_ index: Int) -> Int {
      if index == 0 { return matchScore + startBonus }
      let previous = text[index - 1]
      return matchScore + (previous.isLetter || previous.isNumber ? 0 : wordStartBonus)
    }

    // row[j]: the best score for the query so far with its last character at j.
    var row = [Int](repeating: unreachable, count: text.count)
    for index in text.indices where text[index] == query[0] {
      row[index] = charScore(index) - min(index, 10) * leadingPenalty
    }
    for character in query.dropFirst() {
      var next = [Int](repeating: unreachable, count: text.count)
      // The best earlier match that leaves a gap before `index`, already
      // charged for the characters skipped.
      var gapped = unreachable
      for index in text.indices {
        if index >= 2, row[index - 2] > unreachable {
          gapped = max(gapped, row[index - 2])
        }
        if index >= 2 { gapped = gapped > unreachable ? gapped - gapPenalty : gapped }
        guard text[index] == character else { continue }
        let adjacent = index >= 1 && row[index - 1] > unreachable ? row[index - 1] + contiguityBonus : unreachable
        let best = max(adjacent, gapped)
        if best > unreachable { next[index] = best + charScore(index) }
      }
      row = next
    }
    let best = row.max() ?? unreachable
    return best > unreachable ? best : nil
  }

  private static let matchScore = 16
  private static let startBonus = 32
  private static let wordStartBonus = 24
  private static let contiguityBonus = 20
  private static let gapPenalty = 2
  private static let leadingPenalty = 1

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
