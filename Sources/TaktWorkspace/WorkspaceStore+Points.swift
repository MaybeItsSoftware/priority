import Foundation
import GRDB

/// Reading back what focused work has been worth. Writing an award happens in
/// `completeActiveFocusTask`, inside the same transaction that finishes the
/// block, so a score can never exist for a block that did not end.
extension WorkspaceStore {
  /// Most recent first. `limit` keeps a history pane from loading a year of
  /// blocks to show ten.
  public func focusAwards(limit: Int = 50) throws -> [FocusAward] {
    try database.read { db in
      try FocusAward.order(Column("awardedAt").desc).limit(max(0, limit)).fetchAll(db)
    }
  }

  public func focusAwards(onDayOf date: Date, calendar: Calendar = .current) throws -> [FocusAward] {
    let day = calendar.startOfDay(for: date)
    guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return [] }
    return try database.read { db in
      try FocusAward
        .filter(Column("awardedAt") >= day && Column("awardedAt") < next)
        .order(Column("awardedAt").desc)
        .fetchAll(db)
    }
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

    return try database.read { db in
      func total(_ from: Date?, _ upTo: Date?) throws -> Double {
        var request = FocusAward.all()
        if let from { request = request.filter(Column("awardedAt") >= from) }
        if let upTo { request = request.filter(Column("awardedAt") < upTo) }
        return try Double.fetchOne(db, request.select(sum(Column("points")))) ?? 0
      }
      return FocusPointsSummary(
        today: try total(today, tomorrow),
        last7Days: try total(weekStart, tomorrow),
        allTime: try total(nil, nil),
        blocksToday: try FocusAward
          .filter(Column("awardedAt") >= today && Column("awardedAt") < tomorrow)
          .fetchCount(db))
    }
  }
}
