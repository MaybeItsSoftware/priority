import Foundation

/// Turns Checkvist's `due` string into a `Date`, when it names one.
///
/// Checkvist stores a due date as free text and returns it in whichever shape
/// it was entered — ISO 8601 with or without a time, `yyyy/MM/dd`, an
/// unpadded `yyyy-M-d`, sometimes with a trailing zone. It also stores keywords
/// like `asap` that never resolve to a date at all, which is why the answer is
/// optional rather than an error.
///
/// This lived on `CheckvistTask` in the plugin layer. It moved here because the
/// same parsing is needed by every declaration of that model — including the
/// re-declared one in `applogic-support/AppLogicSharedTypes.swift` — and
/// copying forty lines of date formats into a shadow type is precisely the
/// drift `SharedTypeDriftTests` exists to catch.
public enum DueDateParsing {

  // `nonisolated(unsafe)` because `DateFormatter` is not `Sendable` but these
  // are only ever read. Building them per call is what they replace: parsing a
  // list's worth of due dates was allocating a formatter per task per parse.
  nonisolated(unsafe) private static let iso8601Parsers: [ISO8601DateFormatter] = {
    let internet = ISO8601DateFormatter()
    internet.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate]

    let internetFractional = ISO8601DateFormatter()
    internetFractional.formatOptions = [
      .withInternetDateTime, .withFractionalSeconds, .withDashSeparatorInDate,
    ]

    let fullDate = ISO8601DateFormatter()
    fullDate.formatOptions = [.withFullDate, .withDashSeparatorInDate]

    return [internet, internetFractional, fullDate]
  }()

  nonisolated(unsafe) private static let formatters: [DateFormatter] = {
    // POSIX, so a user's regional settings cannot change how a stored date
    // parses — the string came from the server, not from their locale.
    let locale = Locale(identifier: "en_US_POSIX")

    func formatter(_ format: String) -> DateFormatter {
      let formatter = DateFormatter()
      formatter.locale = locale
      formatter.dateFormat = format
      return formatter
    }

    return [
      formatter("yyyy-MM-dd"),
      formatter("yyyy-M-d"),
      formatter("yyyy-MM-dd HH:mm:ss Z"),
      formatter("yyyy/MM/dd"),
      formatter("yyyy/MM/dd HH:mm:ss Z"),
    ]
  }()

  /// `nil` for an empty string, and for a keyword like `asap` that names no
  /// calendar date.
  public static func date(from due: String?) -> Date? {
    guard let raw = due?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return nil
    }

    for parser in iso8601Parsers {
      if let parsed = parser.date(from: raw) { return parsed }
    }
    for formatter in formatters {
      if let parsed = formatter.date(from: raw) { return parsed }
    }

    // Last resort: take the leading `yyyy-MM-dd` off something that is dated
    // but whose time portion none of the above accepted, rather than losing
    // the day entirely.
    if raw.count >= 10 {
      let dayPrefix = String(raw.prefix(10))
      for formatter in formatters {
        if let parsed = formatter.date(from: dayPrefix) { return parsed }
      }
    }

    return nil
  }
}
