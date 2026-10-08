import Foundation

/// Reading back what focused work has been worth. Writing an award happens in
/// `completeActiveFocusTask`, inside the same transaction that finishes the
/// block, so a score can never exist for a block that did not end.
extension WorkspaceStore {
  /// Most recent first. `limit` keeps a history pane from loading a year of
  /// blocks to show ten.
  public func focusAwards(limit: Int = 50) throws -> [FocusAward] {
    try Self.mappingCoreErrors { try core.recentFocusAwards(limit: Int64(limit)) }.map(FocusAward.init)
  }

  public func focusAwards(onDayOf date: Date, calendar: Calendar = .current) throws -> [FocusAward] {
    let day = calendar.startOfDay(for: date)
    guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return [] }
    return try Self.mappingCoreErrors {
      try core.focusAwardsBetween(fromMs: day.coreMilliseconds, toMs: next.coreMilliseconds)
    }.map(FocusAward.init)
  }

  /// Today, the trailing week, and everything — in one read, so the three
  /// numbers on screen are always from the same moment.
  ///
  /// The week is the seven days ending today, counted by calendar day rather
  /// than by 168 hours: work done on Monday morning should still be in "this
  /// week" on Sunday evening.
  public func focusPointsSummary(now: Date = .now, calendar: Calendar = .current) throws -> FocusPointsSummary {
    let today = calendar.startOfDay(for: now)
    guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
      let weekStart = calendar.date(byAdding: .day, value: -6, to: today)
    else { return .zero }

    let summary = try Self.mappingCoreErrors {
      try core.focusPointsSummary(
        todayMs: today.coreMilliseconds, tomorrowMs: tomorrow.coreMilliseconds,
        weekStartMs: weekStart.coreMilliseconds)
    }
    return FocusPointsSummary(
      today: summary.today, last7Days: summary.last7Days, allTime: summary.allTime,
      blocksToday: Int(summary.blocksToday))
  }
}
