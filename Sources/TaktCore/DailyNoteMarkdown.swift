import Foundation
import TaktRustCore

/// Renders a day into the managed block that gets spliced into an Obsidian
/// daily note, and splices it in.
///
/// The block is delimited by HTML comment markers so it is invisible in
/// Obsidian's reading view, and so re-writing a day is idempotent: the same day
/// written twice replaces its own block rather than stacking duplicates.
/// Everything outside the markers belongs to the user and is never touched.
///
/// The block's text is the Rust core's (`core/src/day_log.rs`); splicing it in
/// stays with `ManagedMarkdownBlock`, which the AFFiNE export shares.
public enum DailyNoteMarkdown {
  /// The block is `ManagedMarkdownBlock.takt`; these two are kept so existing
  /// callers and tests keep reading.
  public static let beginMarker = ManagedMarkdownBlock.takt.beginMarker
  public static let endMarker = ManagedMarkdownBlock.takt.endMarker

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
    // Only the titles the block can name cross the boundary; the caller's
    // dictionary is usually every task in the workspace.
    var titles: [Int64: String] = [:]
    for id in summary.unfinishedTaskIds + summary.deferredTaskIds {
      if let title = titlesByTaskId[id] { titles[Int64(id)] = title }
    }
    return dayLogSection(
      day: summary.core,
      titles: titles,
      dailies: dailies.map { DayLogDaily(id: $0.id, title: $0.title) },
      heading: heading
    )
  }

  /// Splices `section` into `existing`, replacing a previous managed block if
  /// there is one and appending otherwise. See `ManagedMarkdownBlock.merged`
  /// for the half-open-marker rule.
  public static func merged(section: String, into existing: String) -> String {
    ManagedMarkdownBlock.takt.merged(block: section, into: existing)
  }
}
