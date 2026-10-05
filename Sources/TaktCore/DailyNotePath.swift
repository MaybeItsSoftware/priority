import Foundation

/// How a date maps onto a file inside the dailies folder.
///
/// Configurable rather than fixed because every vault names its dailies
/// differently — `2026-08-14.md`, `14-08-2026.md`, `2026/08/2026-08-14.md` — and
/// guessing wrong means writing a *second* note beside the real one rather than
/// failing loudly.
public struct DailyNoteFormat: Equatable, Sendable {
  /// `DateFormatter` pattern for the file's base name, without `.md`.
  public var fileNameFormat: String
  /// `DateFormatter` pattern for intermediate folders, or empty for none.
  /// Slashes are meaningful here: `"yyyy/MM"` nests two levels deep.
  public var folderFormat: String

  public static let `default` = DailyNoteFormat(fileNameFormat: "yyyy-MM-dd", folderFormat: "")

  public init(fileNameFormat: String = "yyyy-MM-dd", folderFormat: String = "") {
    self.fileNameFormat = fileNameFormat
    self.folderFormat = folderFormat
  }
}

public enum DailyNotePath {
  /// The note's path relative to the dailies folder, e.g. `2026/2026-08-14.md`.
  ///
  /// Formatting uses a POSIX locale so the pattern means the same thing on every
  /// machine — under a non-Gregorian system locale an unpinned formatter would
  /// happily produce a Buddhist-calendar year and file the note under 2569.
  public static func relativePath(
    for day: Date,
    format: DailyNoteFormat,
    calendar: Calendar = .current
  ) -> String {
    let fileName = sanitisedComponent(
      formatted(day, pattern: format.fileNameFormat, calendar: calendar)
    )
    let base = fileName.isEmpty ? "daily" : fileName

    let folderPattern = format.folderFormat.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !folderPattern.isEmpty else { return base + ".md" }

    // Each `/`-separated segment is formatted and sanitised on its own, so a
    // stray `..` in one segment can't climb out of the dailies folder.
    let folders = folderPattern
      .split(separator: "/", omittingEmptySubsequences: true)
      .map { sanitisedComponent(formatted(day, pattern: String($0), calendar: calendar)) }
      .filter { !$0.isEmpty }

    return (folders + [base + ".md"]).joined(separator: "/")
  }

  private static func formatted(_ date: Date, pattern: String, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = pattern
    return formatter.string(from: date)
  }

  /// Strips anything that would turn one path component into several, or point
  /// at a parent directory.
  private static func sanitisedComponent(_ raw: String) -> String {
    let illegal = CharacterSet(charactersIn: "/\\:\n\r\t")
    let cleaned = String(raw.unicodeScalars.filter { !illegal.contains($0) })
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned == ".." || cleaned == "." ? "" : cleaned
  }
}
