import Foundation

/// Projections over the raw event log.
///
/// Both the Daily view and the Obsidian note render from these, so the two can
/// never disagree about what a day contained. Everything here is pure: it takes
/// the events it is given and returns a value, which is what makes the whole
/// feature unit-testable without an app, a vault, or a Checkvist account.
///
/// Every entry point assumes `events` is in chronological order —
/// `DayLogFileStore` appends and reads in order, so that holds by construction.
public enum DayLogAggregator {

  /// One bar in the chart. `day` is the instant the logical day (or week, for
  /// the weekly bucketing) began — see `DayBoundary.logicalDay`.
  public struct Bucket: Equatable, Sendable {
    public let day: Date
    public let key: String
    public let completed: Int

    public init(
      day: Date,
      key: String,
      completed: Int
    ) {
    self.day = day
    self.key = key
    self.completed = completed
    }
  }

  /// Everything the Daily view and the note need about a single day.
  ///
  /// `unfinishedTaskIds` is deliberately named for the fact rather than the
  /// judgement: for today it renders as "left", for a day that has already
  /// closed it renders as "slipped". Same data, and the renderer picks the word
  /// so the view never accuses you of slipping on a day still in progress.
  public struct DaySummary: Equatable, Sendable {
    public let key: String
    public let day: Date
    public let completed: [DayLogEvent]
    public let plannedTaskIds: [Int]
    public let unfinishedTaskIds: [Int]
    public let deferredTaskIds: [Int]
    public let invalidatedTaskIds: [Int]
    public let focusSeconds: Int
    /// Dailies ticked off on this day. Held as ids rather than titles because
    /// the caller pairs them against the current list of dailies to work out
    /// which ones are still outstanding.
    public let completedDailyIds: Set<String>

    public var completedCount: Int { completed.count }
    public var plannedCount: Int { plannedTaskIds.count }
    public var unfinishedCount: Int { unfinishedTaskIds.count }

    public static func empty(key: String, day: Date) -> DaySummary {
      DaySummary(
        key: key,
        day: day,
        completed: [],
        plannedTaskIds: [],
        unfinishedTaskIds: [],
        deferredTaskIds: [],
        invalidatedTaskIds: [],
        focusSeconds: 0,
        completedDailyIds: []
      )
    }
  }

  // MARK: - Netting

  /// The completion events that survive their compensating reopens.
  ///
  /// A reopen cancels the most recent surviving completion of the *same task*,
  /// wherever that completion happened — so undoing yesterday's tick removes
  /// yesterday's bar segment rather than silently subtracting one from today's.
  public static func netCompletions(_ events: [DayLogEvent]) -> [DayLogEvent] {
    var openCompletionIndices: [Int: [Int]] = [:]
    var cancelledIndices = Set<Int>()

    for (index, event) in events.enumerated() {
      switch event.kind {
      case .completed:
        openCompletionIndices[event.taskId, default: []].append(index)
      case .reopened:
        if let cancelled = openCompletionIndices[event.taskId]?.popLast() {
          cancelledIndices.insert(cancelled)
        }
      default:
        continue
      }
    }

    return events.enumerated()
      .filter { $0.element.kind == .completed && !cancelledIndices.contains($0.offset) }
      .map(\.element)
  }

  /// The ids of the dailies ticked off on the logical day containing `date`.
  ///
  /// Netted *within the day*, which is the whole difference between a daily and
  /// a task. A task completion stands until something reopens it, whenever that
  /// happens; a daily is asked afresh every morning, so a tick and an un-tick
  /// only ever cancel each other inside the same day. Un-ticking today can't
  /// reach back and blank yesterday's square, and a tick left un-cancelled at
  /// midnight is final.
  public static func completedDailyIds(
    events: [DayLogEvent],
    boundary: DayBoundary,
    on date: Date
  ) -> Set<String> {
    let key = boundary.dayKey(for: date)
    var completed = Set<String>()
    for event in events where boundary.dayKey(for: event.at) == key {
      guard let dailyId = event.dailyId else { continue }
      switch event.kind {
      case .dailyCompleted: completed.insert(dailyId)
      case .dailyUncompleted: completed.remove(dailyId)
      default: continue
      }
    }
    return completed
  }

  /// Daily ticks per logical day, as counts, keyed on the logical day itself.
  ///
  /// Same within-day netting as `completedDailyIds`, done in one pass so the
  /// chart doesn't re-scan the log once per bucket. Keyed on the day rather
  /// than its string form so the weekly roll-up can re-bucket without having to
  /// find an event to recover the date from — `logicalDay` is idempotent, so
  /// the key is stable.
  private static func dailyTickCountsByDay(
    _ events: [DayLogEvent],
    boundary: DayBoundary
  ) -> [Date: Int] {
    var completedByDay: [Date: Set<String>] = [:]
    for event in events {
      guard let dailyId = event.dailyId else { continue }
      let day = boundary.logicalDay(for: event.at)
      switch event.kind {
      case .dailyCompleted: completedByDay[day, default: []].insert(dailyId)
      case .dailyUncompleted: completedByDay[day]?.remove(dailyId)
      default: continue
      }
    }
    return completedByDay.mapValues(\.count)
  }

  // MARK: - Chart buckets

  /// Daily ticks per logical day, zero-filled across the whole window.
  ///
  /// The zero-fill is load-bearing: a day with nothing ticked has to occupy its
  /// slot on the axis and render as a marker on the baseline. Dropping empty
  /// days would compress the gaps and quietly draw a busier history than the
  /// real one.
  ///
  /// Dailies only. Task completions used to be summed in alongside them, on the
  /// reasoning that the chart answered "how much did I get done" — but a day's
  /// task count is whatever happened to be on the list, so it swamped the
  /// dailies and made the line say nothing about the habits it sits under. The
  /// chart belongs to the checklist above it: same denominator every day, so
  /// the shape of the line is the shape of the routine.
  public static func dailyBuckets(
    events: [DayLogEvent],
    boundary: DayBoundary,
    endingOn now: Date,
    days: Int
  ) -> [Bucket] {
    let countsByDay = dailyTickCountsByDay(events, boundary: boundary)
    return boundary.days(endingOn: now, count: days).map { day in
      Bucket(day: day, key: boundary.dayKey(for: day), completed: countsByDay[day] ?? 0)
    }
  }

  /// Daily ticks per calendar week, zero-filled. Used for the year range, where
  /// 365 daily bars would be a few pixels each and unreadable in a popover.
  public static func weeklyBuckets(
    events: [DayLogEvent],
    boundary: DayBoundary,
    endingOn now: Date,
    weeks: Int
  ) -> [Bucket] {
    var countsByWeekStart: [Date: Int] = [:]
    // Netted per day first, then rolled up — netting across a whole week would
    // let Monday's un-tick cancel Tuesday's tick.
    for (day, count) in dailyTickCountsByDay(events, boundary: boundary) {
      countsByWeekStart[boundary.weekStart(for: day), default: 0] += count
    }
    return boundary.weeks(endingOn: now, count: weeks).map { weekStart in
      Bucket(
        day: weekStart,
        key: boundary.dayKey(for: weekStart),
        completed: countsByWeekStart[weekStart] ?? 0
      )
    }
  }

  // MARK: - Day summary

  public static func summary(
    events: [DayLogEvent],
    boundary: DayBoundary,
    on date: Date
  ) -> DaySummary {
    let key = boundary.dayKey(for: date)
    let day = boundary.logicalDay(for: date)
    let onThisDay = events.filter { boundary.dayKey(for: $0.at) == key }

    // Netting runs over the *whole* log, not just this day, because the reopen
    // that cancels one of today's completions may itself land tomorrow.
    let surviving = netCompletions(events)
    let completed = surviving.filter { boundary.dayKey(for: $0.at) == key }

    let planned = onThisDay.last { $0.kind == .planSnapshot }?.plannedTaskIds ?? []
    let deferred = orderedUniqueTaskIds(onThisDay.filter { $0.kind == .deferred })
    let invalidated = orderedUniqueTaskIds(onThisDay.filter { $0.kind == .invalidated })

    // A planned task counts as unfinished only if nothing closed it and it
    // wasn't consciously pushed. Completions from *any* day settle it, so a task
    // finished before its snapshot day never shows up as outstanding.
    let closedTaskIds = Set(surviving.map(\.taskId))
      .union(invalidated)
      .union(deferred)
    let unfinished = planned.filter { !closedTaskIds.contains($0) }

    let focusSeconds = onThisDay
      .filter { $0.kind == .focusSessionEnded }
      .reduce(0) { $0 + ($1.durationSeconds ?? 0) }

    return DaySummary(
      key: key,
      day: day,
      completed: completed,
      plannedTaskIds: planned,
      unfinishedTaskIds: unfinished,
      deferredTaskIds: deferred,
      invalidatedTaskIds: invalidated,
      focusSeconds: focusSeconds,
      completedDailyIds: completedDailyIds(events: events, boundary: boundary, on: date)
    )
  }

  /// The logical days that have at least one event, used to decide whether
  /// there is enough history to be worth drawing a chart at all.
  public static func recordedDayCount(events: [DayLogEvent], boundary: DayBoundary) -> Int {
    Set(events.map { boundary.dayKey(for: $0.at) }).count
  }

  /// Consecutive logical days *before* `now`'s day on which something was
  /// completed, counting back until the first day with nothing.
  ///
  /// Excludes today deliberately, which is what makes it usable from both
  /// completion paths. The task path classifies its milestone *before* the
  /// close is recorded and the daily path *after*, so a streak that counted
  /// today would be one day apart depending on which funnel asked. Excluding it
  /// means the caller always adds the day it is in the middle of earning:
  /// `streakDays = priorCompletionStreak(...) + 1`.
  ///
  /// Both task completions and daily ticks count. A day spent entirely on
  /// recurring intentions is still a day you showed up, and a streak that broke
  /// because the only thing you did was tick your dailies would be measuring
  /// the wrong thing.
  public static func priorCompletionStreak(
    events: [DayLogEvent],
    boundary: DayBoundary,
    now: Date
  ) -> Int {
    guard !events.isEmpty else { return 0 }
    // Tasks net across days — a reopen last week cancels last week's bar — so
    // they come from `netCompletions`. Dailies net *within* a day, which is
    // what `completedDailyIds` already knows, so they are asked per day below
    // rather than folded in here.
    let taskDays = Set(netCompletions(events).map { boundary.dayKey(for: $0.at) })

    var streak = 0
    // Bounded rather than `while true`: a log cannot outrun its own history, and
    // an unbounded walk over a corrupt date would not terminate.
    let horizon = max(1, recordedDayCount(events: events, boundary: boundary)) + 1
    for offset in 1...horizon {
      let day = boundary.day(offsetBy: -offset, from: now)
      let hasTask = taskDays.contains(boundary.dayKey(for: day))
      let hasDaily =
        hasTask || !completedDailyIds(events: events, boundary: boundary, on: day).isEmpty
      guard hasTask || hasDaily else { break }
      streak += 1
    }
    return streak
  }

  /// The earliest logical day in the log — the "collecting since" date the empty
  /// state shows while history builds up.
  public static func firstRecordedDay(events: [DayLogEvent], boundary: DayBoundary) -> Date? {
    guard let earliest = events.map(\.at).min() else { return nil }
    return boundary.logicalDay(for: earliest)
  }

  // MARK: - Helpers

  private static func orderedUniqueTaskIds(_ events: [DayLogEvent]) -> [Int] {
    var seen = Set<Int>()
    var ordered: [Int] = []
    for event in events where !seen.contains(event.taskId) {
      seen.insert(event.taskId)
      ordered.append(event.taskId)
    }
    return ordered
  }
}
