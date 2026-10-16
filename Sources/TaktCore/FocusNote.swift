import Foundation

/// What is said about a block as it finishes — where it got to, what is left —
/// kept with the task it was about.
///
/// It goes on the end of the task's notes as a paragraph of its own, opened by
/// the day it was written, so that a task worked over several blocks collects
/// a short dated log rather than one note overwriting the last.
public enum FocusNote {
  /// `notes` with `note` added as its last paragraph, or `notes` unchanged
  /// when there is nothing to add.
  public static func appending(_ note: String, to notes: String, stamp: String) -> String {
    let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !note.isEmpty else { return notes }
    let entry = "\(stamp) — \(note)"
    let existing = notes.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    return existing.isEmpty ? entry : existing + "\n\n" + entry
  }

  /// The day a note opens with: "16 Oct", in the reader's own order.
  public static func stamp(for date: Date, locale: Locale = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.setLocalizedDateFormatFromTemplate("dMMM")
    return formatter.string(from: date)
  }
}
