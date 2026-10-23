import Foundation
import TaktCore
import TaktRustCore

/// How each day starts: at the hour the day changes, what holds goes back to
/// the conditions you start every day with — Home — with nothing switched
/// off for now and no time window. The Rust core's `day_start`, which keeps
/// it with the account so every device starts the day the same way, and
/// resets once a day whichever device looks first.
public struct DayStart: Equatable, Sendable {
  /// Whether each day starts afresh.
  public var resets: Bool
  /// The hour the day changes, 0 to 23. The daily log's days change then
  /// too: it is the one hour Takt counts days from.
  public var hour: Int
  /// The conditions each day starts with; empty starts it with nothing on.
  public var conditionIDs: Set<String>
  /// The last day reset, `yyyy-MM-dd`.
  public var lastResetDay: String?

  public init(
    resets: Bool = false, hour: Int = DayBoundary.defaultRolloverHour, conditionIDs: Set<String> = [],
    lastResetDay: String? = nil
  ) {
    self.resets = resets; self.hour = hour; self.conditionIDs = conditionIDs; self.lastResetDay = lastResetDay
  }

  init(_ core: DayStartSettings) {
    self.init(
      resets: core.resets, hour: Int(core.hour), conditionIDs: Set(core.conditionIds),
      lastResetDay: core.lastResetDay)
  }

  var core: DayStartSettings {
    DayStartSettings(
      resets: resets, hour: Int32(hour), conditionIds: conditionIDs.sorted(), lastResetDay: lastResetDay)
  }

  /// The day `now` falls in, as a reset counts it: `yyyy-MM-dd`.
  public func dayKey(at now: Date = .now, in zone: TimeZone = .current) -> String {
    dayStartDayKey(hour: Int32(hour), nowMs: now.coreMilliseconds, zone: zone.identifier)
  }

  /// Whether a look at `now` would start the day: it resets, and the day
  /// has changed since it last did. Cheap, for a clock that asks often; the
  /// core decides for certain.
  public func isDue(at now: Date = .now, in zone: TimeZone = .current) -> Bool {
    guard resets else { return false }
    guard let lastResetDay else { return true }
    return lastResetDay < dayKey(at: now, in: zone)
  }
}

extension WorkspaceStore {
  /// How each day starts, as the account keeps it.
  public func dayStart() throws -> DayStart {
    DayStart(try Self.mappingCoreErrors { try core.dayStartSettings() })
  }

  /// Saves how each day starts. Not an undo step. Counts today as started,
  /// so the first reset is at the next change of day, never there and then.
  @discardableResult
  public func setDayStart(_ settings: DayStart, now: Date = .now) throws -> Bool {
    try Self.mappingCoreErrors {
      try core.setDayStartSettings(
        settings: settings.core, nowMs: now.coreMilliseconds, zone: TimeZone.current.identifier)
    }
  }

  /// Brings an hour kept before the account had one (the Mac's daily log)
  /// into the account; whether it did.
  @discardableResult
  public func adoptDayStartHour(_ hour: Int, now: Date = .now) throws -> Bool {
    try Self.mappingCoreErrors { try core.adoptDayStartHour(hour: Int32(hour), nowMs: now.coreMilliseconds) }
  }

  /// Starts the day if it has changed since the last reset; whether what
  /// holds was reset. Every client calls it when it looks: at launch, on
  /// coming to the front, after a pull, and on the clock.
  @discardableResult
  public func applyDayStart(in workspaceId: String, now: Date = .now) throws -> Bool {
    try Self.mappingCoreErrors {
      try core.applyDayStart(
        workspaceId: workspaceId, nowMs: now.coreMilliseconds, zone: TimeZone.current.identifier)
    }
  }
}
