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

  /// Whether the conditions on were said on an earlier day than `now`: a
  /// place left on overnight is probably not where you are. The core's
  /// `focus_context_is_stale`.
  public static func isStale(
    _ active: Set<String>, setAt: Date?, now: Date, timeZone: TimeZone = .current
  ) -> Bool {
    let context = StoredFocusContext(
      conditionIds: Array(active), conditionsSetAtMs: setAt.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) },
      availableUntilMs: nil, expiresAtMs: nil, mode: "progress", suggestedIds: [], offIds: [])
    return focusContextIsStale(
      context: context, nowMs: Int64((now.timeIntervalSince1970 * 1000).rounded()), zone: timeZone.identifier)
  }

  /// `current` with `on` turned on and `off` turned off; a place turned on
  /// turns the other places off. The core's `focus_context_changed`, which
  /// the CLI's `workspace_context_set` applies too.
  public static func changing(
    _ current: Set<String>, on: [String], off: [String] = [], locationIDs: Set<String>
  ) -> Set<String> {
    Set(focusContextChanged(current: Array(current), on: on, off: off, locationIds: Array(locationIDs)))
  }

  /// How many held-back tasks wait on each condition, by id, from each such
  /// task's unmet requirement groups. The core's `condition_waiting_counts`.
  public static func waitingCounts(_ missing: [[[String]]]) -> [String: Int] {
    Dictionary(
      conditionWaitingCounts(missing: missing).map { ($0.conditionId, Int($0.openTasks)) },
      uniquingKeysWith: { first, _ in first })
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
