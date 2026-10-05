import Foundation

/// A recurring thing you intend to do on a schedule — a habit, not a task.
///
/// Deliberately *not* a Checkvist task with a recurrence rule. A task models a
/// piece of work that exists until it is done; a daily models an intention that
/// resets. The difference shows up the moment you miss one: a recurring task
/// goes overdue and starts competing with real deadlines, whereas a missed daily
/// is simply a gap in the history. Nothing to clear, nothing to reschedule.
///
/// Because of that, a `Daily` carries no completion state at all. Whether it is
/// done is a question about *a particular day*, and the answer lives in the
/// append-only day log — see `DayLogAggregator.completedDailyIds`. Storing a
/// `isDoneToday` flag here would need clearing at rollover, and anything that
/// needs clearing at rollover eventually doesn't get cleared.
public struct Daily: Codable, Equatable, Identifiable, Sendable {
  /// Stable across renames and reschedules, because the day log references it.
  /// A `String` rather than a `UUID` so log events stay readable by eye.
  public let id: String
  public var title: String
  /// Which weekdays this is expected on, in `Calendar` numbering (1 = Sunday).
  /// A full set means every day, which is the common case.
  ///
  /// Ignored while `intervalDays` is set — a cycle of "every three days" does
  /// not line up with weekdays, so the two schedules are alternatives rather
  /// than filters that compose. The set is still kept, so switching back to a
  /// weekday schedule restores the days that were chosen before.
  public var activeWeekdays: Set<Int>
  /// Repeat every N days from `intervalAnchor` instead of on fixed weekdays —
  /// the schedule that rotates through the week rather than sitting still in it.
  ///
  /// Nil is the ordinary weekday-scheduled case, which is also what every file
  /// written before this field existed decodes as.
  public var intervalDays: Int?
  /// A day the cycle is known to land on. Nil falls back to `createdAt`, so a
  /// hand-edited file that only adds `intervalDays` still behaves.
  ///
  /// Stored rather than derived because the cycle has to survive a rename, a
  /// reorder, and a rollover — anything recomputed from "today" would silently
  /// re-phase the habit every time it was touched.
  public var intervalAnchor: Date?
  /// Manual display order. Habits are done in a routine order, so this is the
  /// user's arrangement rather than anything derived.
  public var sortIndex: Int
  public var createdAt: Date
  /// Set instead of deleting, so history that references this id still renders
  /// with a title rather than as an orphan.
  public var archivedAt: Date?

  public static let allWeekdays: Set<Int> = [1, 2, 3, 4, 5, 6, 7]
  public static let mondayToFriday: Set<Int> = [2, 3, 4, 5, 6]
  public static let weekend: Set<Int> = [1, 7]
  /// A year is the longest cycle that still reads as a habit; past that it is a
  /// calendar event. Clamped rather than rejected so a stray number in a
  /// hand-edited file can't make a daily that never comes round again.
  public static let intervalRange = 1...366

  public init(
    id: String = UUID().uuidString,
    title: String,
    activeWeekdays: Set<Int> = Daily.allWeekdays,
    intervalDays: Int? = nil,
    intervalAnchor: Date? = nil,
    sortIndex: Int = 0,
    createdAt: Date = Date(),
    archivedAt: Date? = nil
  ) {
    self.id = id
    self.title = title
    self.activeWeekdays = activeWeekdays.isEmpty ? Daily.allWeekdays : activeWeekdays
    self.intervalDays = intervalDays.map { Daily.clampInterval($0) }
    self.intervalAnchor = intervalAnchor
    self.sortIndex = sortIndex
    self.createdAt = createdAt
    self.archivedAt = archivedAt
  }

  public static func clampInterval(_ days: Int) -> Int {
    min(intervalRange.upperBound, max(intervalRange.lowerBound, days))
  }

  private enum CodingKeys: String, CodingKey {
    case id, title, activeWeekdays, intervalDays, intervalAnchor, sortIndex, createdAt, archivedAt
  }

  /// Hand-written purely to sort `activeWeekdays` on the way out.
  ///
  /// `Set` has no order, so the synthesised encoder emits whatever the hash
  /// happens to give — which changes between runs. That made every save a
  /// spurious diff in a file the user is invited to edit by hand, and made the
  /// file impossible to compare byte-for-byte against the one the MCP server
  /// writes (see `scripts/mcp_parity_check.py`). Decoding stays synthesised; a
  /// `Set` reads back from an array either way.
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(title, forKey: .title)
    try container.encode(activeWeekdays.sorted(), forKey: .activeWeekdays)
    try container.encodeIfPresent(intervalDays, forKey: .intervalDays)
    try container.encodeIfPresent(intervalAnchor, forKey: .intervalAnchor)
    try container.encode(sortIndex, forKey: .sortIndex)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encodeIfPresent(archivedAt, forKey: .archivedAt)
  }

  public var isArchived: Bool { archivedAt != nil }

  public var isEveryDay: Bool {
    if let intervalDays { return intervalDays <= 1 }
    return activeWeekdays == Daily.allWeekdays
  }

  /// Whether this is expected on the logical day beginning at `day`.
  ///
  /// Takes the *logical* day start, so a daily ticked at 01:00 under a 4am
  /// rollover is still measured against the weekday it belongs to rather than
  /// the one the wall clock has moved on to.
  public func isDue(on day: Date, calendar: Calendar = .current) -> Bool {
    guard !isArchived else { return false }
    if let intervalDays {
      guard intervalDays > 1 else { return true }
      let anchor = calendar.startOfDay(for: intervalAnchor ?? createdAt)
      let target = calendar.startOfDay(for: day)
      guard let delta = calendar.dateComponents([.day], from: anchor, to: target).day else {
        return true
      }
      // Modulo that stays non-negative, so the cycle also extends *backwards*
      // from the anchor. Otherwise a daily anchored today would read as "not
      // due" for every day already in the log, and the history behind it would
      // be full of gaps it was never expected on.
      return ((delta % intervalDays) + intervalDays) % intervalDays == 0
    }
    return activeWeekdays.contains(calendar.component(.weekday, from: day))
  }

  /// "Every day", "Every 3 days", "Weekdays", or an abbreviated list. Shown next
  /// to the title only when it isn't every day — the common case needs no
  /// annotation.
  public var scheduleLabel: String { Daily.scheduleLabel(for: schedule) }

  /// The same wording for a schedule that isn't attached to a daily yet, so the
  /// "new daily" control and the row it becomes can't drift apart.
  public static func scheduleLabel(for schedule: Schedule) -> String {
    switch schedule {
    case .everyNDays(let days):
      if days <= 1 { return "Every day" }
      if days == 2 { return "Every other day" }
      return "Every \(days) days"
    case .weekdays(let days):
      if days == Daily.allWeekdays { return "Every day" }
      if days == Daily.mondayToFriday { return "Weekdays" }
      if days == Daily.weekend { return "Weekends" }
      let names = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
      return days.sorted().filter(Daily.allWeekdays.contains).map { names[$0] }
        .joined(separator: " ")
    }
  }

  // MARK: - Schedule

  /// The two ways a daily can recur, as one value.
  ///
  /// The stored fields are what the file has to contain — an optional interval
  /// beside a weekday set — but every caller that *chooses* a schedule is
  /// choosing between them, and a pair of fields where only one applies is the
  /// kind of thing UI code gets subtly wrong.
  public enum Schedule: Equatable, Sendable {
    case weekdays(Set<Int>)
    case everyNDays(Int)
  }

  public var schedule: Schedule {
    if let intervalDays { return .everyNDays(intervalDays) }
    return .weekdays(activeWeekdays)
  }

  /// Applies a schedule, anchoring a newly-chosen cycle at `anchor`.
  ///
  /// An existing anchor is kept when only the length changes, so nudging "every
  /// 3 days" to "every 4" re-spaces the habit rather than restarting it — and
  /// switching to weekdays clears the cycle entirely rather than leaving a
  /// stale anchor for a future switch to inherit.
  public mutating func setSchedule(_ schedule: Schedule, anchor: Date = Date()) {
    switch schedule {
    case .weekdays(let days):
      activeWeekdays = days.isEmpty ? Daily.allWeekdays : days
      intervalDays = nil
      intervalAnchor = nil
    case .everyNDays(let days):
      intervalDays = Daily.clampInterval(days)
      intervalAnchor = intervalAnchor ?? anchor
    }
  }
}

/// The whole set of dailies, as persisted.
///
/// Wrapped in a struct rather than stored as a bare array so the file has a
/// version field from day one — the alternative is discovering you need one
/// after there is data in the wild.
public struct DailyCollection: Codable, Equatable, Sendable {
  public var version: Int
  public var dailies: [Daily]

  public init(dailies: [Daily] = []) {
    self.version = 1
    self.dailies = dailies
  }

  /// Active dailies in display order, filtered to those expected on `day`.
  public func due(on day: Date, calendar: Calendar = .current) -> [Daily] {
    dailies
      .filter { $0.isDue(on: day, calendar: calendar) }
      .sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
  }

  /// Every non-archived daily in display order, regardless of schedule. What
  /// the settings editor lists.
  public var active: [Daily] {
    dailies
      .filter { !$0.isArchived }
      .sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
  }

  public func daily(withId id: String) -> Daily? {
    dailies.first { $0.id == id }
  }

  /// Appends at the end of the current order.
  public mutating func add(_ daily: Daily) {
    var daily = daily
    daily.sortIndex = (dailies.map(\.sortIndex).max() ?? -1) + 1
    dailies.append(daily)
  }

  public mutating func update(id: String, _ transform: (inout Daily) -> Void) {
    guard let index = dailies.firstIndex(where: { $0.id == id }) else { return }
    transform(&dailies[index])
  }

  /// Archives rather than removes, so past days that referenced it still render
  /// with a title instead of an orphaned id.
  public mutating func archive(id: String, at date: Date = Date()) {
    update(id: id) { $0.archivedAt = date }
  }

  /// Un-archives, putting the daily back in `active` at its old sort position.
  ///
  /// The inverse of `archive`, and the reason archiving can be offered as
  /// "delete" without a confirmation step: nothing has been lost, so the undo is
  /// simply doing it again the other way.
  public mutating func restore(id: String) {
    update(id: id) { $0.archivedAt = nil }
  }

  /// Moves a daily by `offset` places within the active order, renumbering the
  /// whole list so indices stay dense.
  public mutating func move(id: String, by offset: Int) {
    var ordered = active
    guard let from = ordered.firstIndex(where: { $0.id == id }) else { return }
    let to = min(ordered.count - 1, max(0, from + offset))
    guard to != from else { return }
    let moved = ordered.remove(at: from)
    ordered.insert(moved, at: to)
    for (index, daily) in ordered.enumerated() {
      update(id: daily.id) { $0.sortIndex = index }
    }
  }
}
