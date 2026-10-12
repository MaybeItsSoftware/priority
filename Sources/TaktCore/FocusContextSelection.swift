import Foundation
import TaktRustCore

/// What "available now" means as a set of condition ids, worked out without
/// the app: turning one on or off, and what a saved context is worth on the
/// next launch.
///
/// The rules are the Rust core's (`core/src/shaping.rs`), which the iPhone's
/// focus model reaches through here and Android's `FocusViewModel` calls
/// directly.
public enum FocusContextSelection {
  /// The set with `conditionID` flipped. You are in one place at a time, so
  /// turning a location on turns every other location off; capabilities
  /// ("Floor space", "Quiet") combine freely.
  public static func toggling(
    _ conditionID: String, isLocation: Bool, in current: Set<String>, locationIDs: Set<String>
  ) -> Set<String> {
    Set(
      focusContextToggle(
        conditionId: conditionID, isLocation: isLocation, current: Array(current),
        locationIds: Array(locationIDs)))
  }

  /// A saved context, less any condition that no longer exists. Archived ones
  /// stay: archiving hides a condition from new requirements, not from tasks
  /// that already need it.
  public static func restoring(_ saved: [String], known: Set<String>) -> Set<String> {
    Set(focusContextRestore(saved: saved, known: Array(known)))
  }

  /// The context in a few words, for a status bar: the names in the order the
  /// conditions are listed, or `nil` with nothing on.
  public static func summary(_ active: Set<String>, names: [(id: String, name: String)]) -> String? {
    let on = names.filter { active.contains($0.id) }.map(\.name)
    return on.isEmpty ? nil : on.joined(separator: " · ")
  }
}

/// When a deferred task comes back: in an hour, at two this afternoon (or an
/// hour from now once that has passed), nine tomorrow, nine a week from
/// today. The arithmetic is the core's `focus_deferral_date`, shared with
/// Android.
public enum FocusDeferralTime: String, CaseIterable, Sendable {
  case anHour, thisAfternoon, tomorrow, nextWeek

  public func date(from now: Date, calendar: Calendar = .current) -> Date {
    let kind: TaktRustCore.FocusDeferral =
      switch self {
      case .anHour: .anHour
      case .thisAfternoon: .thisAfternoon
      case .tomorrow: .tomorrow
      case .nextWeek: .nextWeek
      }
    let nowMs = Int64((now.timeIntervalSince1970 * 1000).rounded())
    let ms = focusDeferralDate(deferral: kind, nowMs: nowMs, zone: calendar.timeZone.identifier)
    // "An hour from now" is measured from `now` itself, which keeps its
    // sub-millisecond part; a wall-clock answer is exact as it is.
    if ms - nowMs == 3_600_000 { return now.addingTimeInterval(3_600) }
    return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
  }
}
