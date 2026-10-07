import Foundation

/// A region of a markdown file that Takt owns, delimited by HTML comment
/// markers, inside a file that otherwise belongs to the user.
///
/// This is the one rule for writing into somebody's vault: Takt may rewrite
/// what sits between its own markers and nothing else. The markers are HTML
/// comments so they are invisible in Obsidian's reading view, and re-writing
/// is idempotent — the same block written twice replaces itself rather than
/// stacking. `DailyNoteMarkdown` uses it for the day's log section;
/// `ObsidianSyncService` for a task's note, where it replaced a whole-file
/// overwrite that silently discarded anything the user had added.
public struct ManagedMarkdownBlock: Equatable, Sendable {
  public let beginMarker: String
  public let endMarker: String

  /// The markers Takt has always used. "priority" is the app's old name, kept
  /// here on purpose: it is stored data, in notes written before the rename.
  public static let takt = ManagedMarkdownBlock(
    beginMarker: "<!-- priority:begin -->",
    endMarker: "<!-- priority:end -->"
  )

  public init(beginMarker: String, endMarker: String) {
    self.beginMarker = beginMarker
    self.endMarker = endMarker
  }

  /// `body` with the markers on their own lines around it.
  public func wrap(_ body: String) -> String {
    [beginMarker, body, endMarker].joined(separator: "\n")
  }

  /// The range of a well-formed block — a begin marker with an end marker
  /// somewhere after it — or nil.
  ///
  /// A begin marker with no end *after* it is not a block. Treating it as one
  /// would consume everything the user wrote below it, and a duplicate block
  /// they can delete is a far better failure than prose that is silently gone.
  public func range(in document: String) -> Range<String.Index>? {
    guard
      let beginRange = document.range(of: beginMarker),
      let endRange = document.range(of: endMarker, range: beginRange.upperBound..<document.endIndex)
    else { return nil }
    return beginRange.lowerBound..<endRange.upperBound
  }

  /// Whether `document` holds a well-formed block.
  public func contains(_ document: String) -> Bool {
    range(in: document) != nil
  }

  /// Splices `block` — markers included — into `existing`, replacing a previous
  /// block if there is one and appending otherwise. Text outside the markers
  /// is returned byte for byte.
  public func merged(block: String, into existing: String) -> String {
    guard let range = range(in: existing) else {
      return appended(block: block, to: existing)
    }
    var merged = existing
    merged.replaceSubrange(range, with: block)
    return merged
  }

  /// `merged(block:into:)` for a bare body: wraps it first.
  public func merging(body: String, into existing: String) -> String {
    merged(block: wrap(body), into: existing)
  }

  private func appended(block: String, to existing: String) -> String {
    let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return block + "\n" }
    return trimmed + "\n\n" + block + "\n"
  }
}
