import Foundation
import TaktRustCore

/// What Priority writes into an AFFiNE document, and how it rewrites its own
/// half of one it has written before.
///
/// AFFiNE stores documents as CRDT blocks, not text: markdown goes in through
/// an importer and comes back out through an exporter, and anything the
/// importer has no block for is dropped on the way in. That rules out
/// `DailyNoteMarkdown`'s HTML-comment markers — invisible in Obsidian, but
/// there is no comment block in AFFiNE for them to survive as. So the managed
/// region here is delimited by a *heading*, which round-trips because it is a
/// real block.
///
/// The documents and the splicing are the Rust core's (`core/src/affine.rs`),
/// one call per document. What stays here is date formatting in the caller's
/// calendar — the sync stamp and the day's title, whose pattern is a
/// user-chosen `DateFormatter` format — and taking `DailyNoteMarkdown`'s
/// markers off a rendered day.
public enum AFFiNEDocumentMarkdown {

  /// The heading Priority owns in a day's document.
  public static let dayHeading = "## Log"

  // MARK: - Day documents

  /// The title of the document a day is written into. Matches the daily-note
  /// file name pattern so a vault and a workspace name the same day the same
  /// way.
  public static func dayDocumentTitle(
    for day: Date,
    pattern: String = DailyNoteFormat.default.fileNameFormat,
    calendar: Calendar = .current
  ) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = pattern.isEmpty ? DailyNoteFormat.default.fileNameFormat : pattern
    return formatter.string(from: day)
  }

  /// `DailyNoteMarkdown`'s rendering of a day, with the comment markers taken
  /// off. The day reads the same in both places because it is rendered once;
  /// only the delimiters differ.
  public static func daySection(from renderedSection: String) -> String {
    renderedSection
      .split(separator: "\n", omittingEmptySubsequences: false)
      .filter {
        let trimmed = $0.trimmingCharacters(in: .whitespaces)
        return trimmed != DailyNoteMarkdown.beginMarker && trimmed != DailyNoteMarkdown.endMarker
      }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Splices `section` into `existing`, replacing the block that `heading`
  /// already owns and appending it otherwise.
  ///
  /// The block ends at the next heading of the same level or shallower, so a
  /// `###` subsection Priority wrote is replaced along with it, while the `##`
  /// the user wrote underneath survives.
  public static func merged(
    section: String,
    heading: String = dayHeading,
    into existing: String
  ) -> String {
    affineMerged(section: section, heading: heading, existing: existing)
  }

  /// What is written under `heading`, heading line excluded, or `nil` when the
  /// document has no such heading — which is the difference between "the
  /// section is empty" and "there is no section", and the two mean different
  /// things to a caller deciding whether to create one.
  public static func body(under heading: String, in markdown: String) -> String? {
    affineBodyUnder(heading: heading, markdown: markdown)
  }

}
