import Foundation
import TaktRustCore

/// Which day a finished thing belongs to, as a *relation* rather than a string.
///
/// The label is left to the view because the words are locale business and the
/// grouping is not: "Today", "Yesterday" and a weekday name are three different
/// sentences about the same arithmetic, and only the arithmetic is worth a test.
public enum CompletedWorkDayKind: Sendable, Equatable {
  case today
  case yesterday
  /// Within the last week, so a weekday name still identifies it unambiguously.
  case thisWeek
  /// Long enough ago that it needs a date.
  case earlier
}

/// One day's worth of finished work.
public struct CompletedWorkGroup<Item>: Identifiable {
  public let dayStart: Date
  public let kind: CompletedWorkDayKind
  public let items: [Item]

  public var id: Date { dayStart }

  public init(dayStart: Date, kind: CompletedWorkDayKind, items: [Item]) {
    self.dayStart = dayStart
    self.kind = kind
    self.items = items
  }
}

/// Buckets finished work into days, newest first.
///
/// A flat list of everything you have closed is not progress you can read: the
/// question is "what did I get done today, and was that a normal day", which
/// needs the day boundaries drawn before anything else. Kept out of the view so
/// the boundary arithmetic — which is the part that goes wrong around midnight
/// and around a week's edge — can be tested without a window.
public enum CompletedWorkDigest {
  /// Groups `items` by the calendar day of `completedAt`, days newest first and
  /// each day's own items newest first. The Rust core's
  /// `progress::group_completed_work`, which hands back indices, so only the
  /// moments cross.
  public static func group<Item>(
    _ items: [Item],
    completedAt: (Item) -> Date,
    now: Date = .now,
    calendar: Calendar = .current
  ) -> [CompletedWorkGroup<Item>] {
    groupCompletedWork(
      completedAtMs: items.map { completedAt($0).rankingMilliseconds }, nowMs: now.rankingMilliseconds,
      zone: calendar.timeZone.identifier
    ).map { day in
      CompletedWorkGroup(
        dayStart: Date(rankingMilliseconds: day.dayStartMs), kind: CompletedWorkDayKind(core: day.kind),
        items: day.items.map { items[Int($0)] })
    }
  }

  /// How far back `day` is from the day containing `now`, counted in days
  /// rather than against a rolling interval of seconds: something closed at
  /// eleven last night is yesterday. Both ends are taken to the start of
  /// their day first, so a caller may pass the moment something was finished.
  /// The Rust core's `progress::completed_day_kind`.
  public static func kind(
    of day: Date,
    now: Date = .now,
    calendar: Calendar = .current
  ) -> CompletedWorkDayKind {
    CompletedWorkDayKind(
      core: completedDayKind(
        dayMs: day.rankingMilliseconds, nowMs: now.rankingMilliseconds, zone: calendar.timeZone.identifier))
  }
}

extension CompletedWorkDayKind {
  init(core kind: CompletedDayKind) {
    switch kind {
    case .today: self = .today
    case .yesterday: self = .yesterday
    case .thisWeek: self = .thisWeek
    case .earlier: self = .earlier
    }
  }
}
