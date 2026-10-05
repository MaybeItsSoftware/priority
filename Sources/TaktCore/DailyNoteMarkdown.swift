import Foundation

/// Renders a day into the managed block that gets spliced into an Obsidian
/// daily note, and splices it in.
///
/// The block is delimited by HTML comment markers so it is invisible in
/// Obsidian's reading view, and so re-writing a day is idempotent: the same day
/// written twice replaces its own block rather than stacking duplicates.
/// Everything outside the markers belongs to the user and is never touched.
public enum DailyNoteMarkdown {
  public static let beginMarker = "<!-- priority:begin -->"
  public static let endMarker = "<!-- priority:end -->"

  /// The managed block for a day, markers included.
  /// - Parameter dailies: the dailies that were expected on this day, in
  ///   display order. Passed in rather than read from the summary because the
  ///   log only records what was *ticked* — knowing what was expected and
  ///   missed needs the schedule, which is configuration, not history.
  public static func section(
    summary: DayLogAggregator.DaySummary,
    titlesByTaskId: [Int: String] = [:],
    dailies: [Daily] = [],
    heading: String = "## Log"
  ) -> String {
    var lines: [String] = [beginMarker, heading, ""]

    var headline = [
      "**\(DayLogFormatting.pluralised(summary.completedCount, "done", "done"))**"
    ]
    if !dailies.isEmpty {
      let done = dailies.filter { summary.completedDailyIds.contains($0.id) }.count
      headline.append("**\(done)/\(dailies.count) dailies**")
    }
    if summary.focusSeconds > 0 {
      headline.append("**\(DayLogFormatting.focusDuration(seconds: summary.focusSeconds)) focused**")
    }
    if summary.plannedCount > 0 {
      headline.append("\(summary.unfinishedCount) of \(summary.plannedCount) planned left")
    }
    lines.append(headline.joined(separator: " · "))
    lines.append("")

    if !dailies.isEmpty {
      lines.append("_Dailies:_")
      for daily in dailies {
        let done = summary.completedDailyIds.contains(daily.id)
        lines.append("- [\(done ? "x" : " ")] \(escapedTitle(daily.title))")
      }
      lines.append("")
    }

    if summary.completed.isEmpty {
      // Only "nothing recorded" when there is genuinely nothing above it —
      // a day where the dailies got done is not a blank day.
      if dailies.isEmpty { lines.append("_Nothing recorded._") }
    } else {
      for event in summary.completed {
        lines.append("- [x] \(escapedTitle(event.title))")
      }
    }

    let unfinishedTitles = summary.unfinishedTaskIds.compactMap { titlesByTaskId[$0] }
    if !unfinishedTitles.isEmpty {
      lines.append("")
      lines.append("_Unfinished:_")
      for title in unfinishedTitles {
        lines.append("- [ ] \(escapedTitle(title))")
      }
    }

    let deferredTitles = summary.deferredTaskIds.compactMap { titlesByTaskId[$0] }
    if !deferredTitles.isEmpty {
      lines.append("")
      lines.append("_Deferred:_")
      for title in deferredTitles {
        lines.append("- \(escapedTitle(title))")
      }
    }

    lines.append(endMarker)
    return lines.joined(separator: "\n")
  }

  /// Splices `section` into `existing`, replacing a previous managed block if
  /// there is one and appending otherwise.
  ///
  /// If a begin marker appears without a matching end *after* it, the note is
  /// treated as having no managed block and a fresh one is appended. Replacing
  /// on a half-open marker would consume everything the user wrote below it,
  /// and a duplicate block they can delete is a far better failure than prose
  /// that is silently gone.
  public static func merged(section: String, into existing: String) -> String {
    guard
      let beginRange = existing.range(of: beginMarker),
      let endRange = existing.range(of: endMarker, range: beginRange.upperBound..<existing.endIndex)
    else {
      return appended(section: section, to: existing)
    }

    var merged = existing
    merged.replaceSubrange(beginRange.lowerBound..<endRange.upperBound, with: section)
    return merged
  }

  private static func appended(section: String, to existing: String) -> String {
    let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return section + "\n" }
    return trimmed + "\n\n" + section + "\n"
  }

  /// Task titles are arbitrary user text landing in a markdown list. Leading
  /// list/heading punctuation would otherwise restructure the note, and a
  /// newline would break the item in half.
  private static func escapedTitle(_ raw: String) -> String {
    let collapsed = raw
      .replacingOccurrences(of: "\r\n", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !collapsed.isEmpty else { return "(untitled)" }

    if let first = collapsed.first, "-*+#>".contains(first) {
      return "\\" + collapsed
    }
    return collapsed
  }
}
