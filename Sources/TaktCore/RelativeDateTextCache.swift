import Foundation

/// Formatted relative dates ("tomorrow", "in 3 days"), kept for a short while.
///
/// `Date.formatted(.relative(presentation: .named))` costs tens of
/// microseconds a call, and a list that says "Due tomorrow" on each row was
/// paying that for every row on every redraw — an arrow key redraws the list.
/// The text only moves as the clock does, so a reading is reused until it is
/// `lifetime` old: a minute by default, finer than anything a named relative
/// date says.
@MainActor
public final class RelativeDateTextCache {
  /// The one the views share.
  public static let shared = RelativeDateTextCache()

  private struct Entry {
    let text: String
    let readAt: Date
  }

  private let lifetime: TimeInterval
  private let capacity: Int
  private let format: (Date, Date) -> String
  private var entries: [Date: Entry] = [:]

  /// - Parameters:
  ///   - lifetime: how long a reading stays good.
  ///   - capacity: entries kept before the stale ones are swept.
  ///   - format: the formatting being saved, given the date and the "now"
  ///     the reading is stamped with.
  public init(
    lifetime: TimeInterval = 60,
    capacity: Int = 512,
    format: @escaping (Date, Date) -> String = RelativeDateTextCache.namedRelative
  ) {
    self.lifetime = lifetime
    self.capacity = capacity
    self.format = format
  }

  /// `date` relative to `now`, from the cache when a reading is fresh enough.
  public func text(for date: Date, now: Date = .now) -> String {
    if let entry = entries[date], abs(now.timeIntervalSince(entry.readAt)) < lifetime {
      return entry.text
    }
    if entries.count >= capacity {
      entries = entries.filter { abs(now.timeIntervalSince($0.value.readAt)) < lifetime }
      if entries.count >= capacity { entries.removeAll(keepingCapacity: true) }
    }
    let text = format(date, now)
    entries[date] = Entry(text: text, readAt: now)
    return text
  }

  /// The formatting the day list uses: "tomorrow", "in 3 days", "yesterday",
  /// measured against the clock as it is when the call is made.
  public nonisolated static func namedRelative(_ date: Date, now _: Date) -> String {
    date.formatted(.relative(presentation: .named))
  }
}
