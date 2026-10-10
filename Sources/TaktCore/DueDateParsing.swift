import Foundation
import TaktRustCore

/// Turns Checkvist's `due` string into a `Date`, when it names one.
///
/// Checkvist stores a due date as free text and returns it in whichever shape
/// it was entered — ISO 8601 with or without a time, `yyyy/MM/dd`, an
/// unpadded `yyyy-M-d`, sometimes with a trailing zone. It also stores keywords
/// like `asap` that never resolve to a date at all, which is why the answer is
/// optional rather than an error.
///
/// The reading is the Rust core's `checkvist_due_date` (`core/src/capture.rs`),
/// which Android calls too. It reproduces what Foundation's parsers answered
/// here: an internet date-time is that moment, and anything else starting
/// with a year, month and day is that day's midnight in UTC.
///
/// This lived on `CheckvistTask` in the plugin layer. It moved here because the
/// same parsing is needed by every declaration of that model — including the
/// re-declared one in `applogic-support/AppLogicSharedTypes.swift`.
public enum DueDateParsing {
  /// `nil` for an empty string, and for a keyword like `asap` that names no
  /// calendar date.
  public static func date(from due: String?) -> Date? {
    checkvistDueDate(due: due).map { Date(rankingMilliseconds: $0) }
  }
}
