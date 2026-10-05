import Foundation

/// Shared number/duration formatting for the daily log.
///
/// Lives here rather than in either renderer so the Daily view and the Obsidian
/// note phrase the same day identically — a note saying "1h 40m" beside a view
/// saying "100m" reads like two different measurements of two different things.
public enum DayLogFormatting {
  /// `"—"` for nothing, `"45m"` under an hour, `"1h 40m"` above it. Deliberately
  /// not fractional hours: "1.7h" is a number you have to convert before it
  /// means anything.
  public static func focusDuration(seconds: Int) -> String {
    guard seconds > 0 else { return "—" }
    let totalMinutes = seconds / 60
    guard totalMinutes >= 60 else { return "\(max(1, totalMinutes))m" }
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
  }

  public static func pluralised(_ count: Int, _ singular: String, _ plural: String) -> String {
    "\(count) \(count == 1 ? singular : plural)"
  }
}
