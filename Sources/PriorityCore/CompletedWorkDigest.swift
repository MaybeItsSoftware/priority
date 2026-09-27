import Foundation

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
  /// each day's own items newest first.
  public static func group<Item>(
    _ items: [Item],
    completedAt: (Item) -> Date,
    now: Date = .now,
    calendar: Calendar = .current
  ) -> [CompletedWorkGroup<Item>] {
    let buckets = Dictionary(grouping: items) { calendar.startOfDay(for: completedAt($0)) }
    return buckets.keys.sorted(by: >).map { dayStart in
      CompletedWorkGroup(
        dayStart: dayStart,
        kind: kind(of: dayStart, now: now, calendar: calendar),
        items: buckets[dayStart, default: []].sorted { completedAt($0) > completedAt($1) })
    }
  }

  /// How far back `dayStart` is from the day containing `now`.
  ///
  /// Counted in days rather than compared against a rolling interval of
  /// seconds: something closed at eleven last night is yesterday, not "twelve
  /// hours ago", and a user reading the rail at nine in the morning means the
  /// same thing by it.
  /// Both ends are taken to the start of their day first, so a caller may pass
  /// the moment something was finished rather than having to normalise it — the
  /// version that trusted its argument read "yesterday at eleven" as today.
  public static func kind(
    of day: Date,
    now: Date = .now,
    calendar: Calendar = .current
  ) -> CompletedWorkDayKind {
    let today = calendar.startOfDay(for: now)
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: day), to: today).day ?? 0
    switch days {
    case ..<1: return .today
    case 1: return .yesterday
    // Six, not seven: at seven days a weekday name names two days and picks the
    // wrong one.
    case 2...6: return .thisWeek
    default: return .earlier
    }
  }
}
