import Foundation

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
public enum AFFiNEDocumentMarkdown {

  /// The heading Priority owns in a day's document.
  public static let dayHeading = "## Log"

  // MARK: - Task documents

  /// A document title for a task. Single-line, because a title that contains a
  /// newline arrives in AFFiNE as a title plus a stray paragraph.
  public static func title(forTaskContent content: String) -> String {
    let collapsed = content
      .replacingOccurrences(of: "\r\n", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return collapsed.isEmpty ? "Untitled task" : collapsed
  }

  /// The body of a task's document — everything but the title, which AFFiNE
  /// carries separately and would otherwise be repeated as an H1.
  public static func taskDocument(
    taskContent: String,
    permalink: String?,
    taskId: Int,
    notes: [String],
    syncDate: Date,
    calendar: Calendar = .current
  ) -> String {
    var lines: [String] = []

    if let permalink, !permalink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      lines.append("[Open in Checkvist](\(permalink))")
    } else {
      lines.append("Task ID: \(taskId)")
    }
    lines.append("")
    lines.append("_Synced from Takt · \(timestamp(syncDate, calendar: calendar))_")
    lines.append("")
    lines.append("## Notes")
    lines.append("")

    let contents = notes.filter {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    if contents.isEmpty {
      lines.append("_No notes_")
    } else {
      for content in contents {
        lines.append(content.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("")
      }
      lines.removeLast()
    }

    return lines.joined(separator: "\n")
  }

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
    let trimmedSection = section.trimmingCharacters(in: .whitespacesAndNewlines)
    let lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

    guard let range = blockRange(for: heading, in: lines) else {
      return appended(section: trimmedSection, to: existing)
    }
    let start = range.lowerBound
    let end = range.upperBound

    var merged = Array(lines[lines.startIndex..<start])
    merged.append(contentsOf: trimmedSection.split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init))
    if end < lines.endIndex {
      merged.append("")
      merged.append(contentsOf: lines[end..<lines.endIndex])
    }
    return merged.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
  }

  /// The lines a heading owns: the heading itself, and everything up to the
  /// next heading of the same level or shallower.
  private static func blockRange(for heading: String, in lines: [String]) -> Range<Int>? {
    let level = headingLevel(heading) ?? 2
    guard
      let start = lines.firstIndex(where: {
        $0.trimmingCharacters(in: .whitespaces) == heading.trimmingCharacters(in: .whitespaces)
      })
    else { return nil }

    let rest = lines.index(after: start)..<lines.endIndex
    let end =
      lines[rest].firstIndex(where: { line in
        guard let candidate = headingLevel(line) else { return false }
        return candidate <= level
      }) ?? lines.endIndex

    return start..<end
  }

  /// What is written under `heading`, heading line excluded, or `nil` when the
  /// document has no such heading — which is the difference between "the
  /// section is empty" and "there is no section", and the two mean different
  /// things to a caller deciding whether to create one.
  public static func body(under heading: String, in markdown: String) -> String? {
    let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let range = blockRange(for: heading, in: lines) else { return nil }
    return lines[lines.index(after: range.lowerBound)..<range.upperBound]
      .joined(separator: "\n")
      .trimmingCharacters(in: .newlines)
  }

  private static func appended(section: String, to existing: String) -> String {
    let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return section + "\n" }
    return trimmed + "\n\n" + section + "\n"
  }

  /// The `#` count of an ATX heading, or `nil` for anything that is not one.
  private static func headingLevel(_ line: String) -> Int? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let hashes = trimmed.prefix(while: { $0 == "#" }).count
    guard hashes > 0, hashes <= 6 else { return nil }
    let remainder = trimmed.dropFirst(hashes)
    guard remainder.first == " " else { return nil }
    return hashes
  }

  private static func timestamp(_ date: Date, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
  }
}
