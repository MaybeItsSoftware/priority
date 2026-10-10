import Foundation
import TaktRustCore

/// Projections over the raw event log.
///
/// Both the Daily view and the Obsidian note render from these, so the two can
/// never disagree about what a day contained. Everything here is pure: it takes
/// the events it is given and returns a value, which is what makes the whole
/// feature unit-testable without an app, a vault, or a Checkvist account.
///
/// Every entry point assumes `events` is in chronological order —
/// `DayLogFileStore` appends and reads in order, so that holds by construction.
/// The rules themselves are the Rust core's.
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

  // MARK: - Projections
  //
  // The rules are the Rust core's (`core/src/day_log.rs`), shared with the
  // CLI's `daily_log_fetch`. These take an array, so every call passes the
  // whole of it across the boundary; the Daily plugin holds its log in the
  // core instead (`DayLogHistory`) and asks it directly.

  /// The completion events that survive their compensating reopens.
  ///
  /// A reopen cancels the most recent surviving completion of the *same task*,
  /// wherever that completion happened — so undoing yesterday's tick removes
  /// yesterday's bar segment rather than silently subtracting one from today's.
  public static func netCompletions(_ events: [DayLogEvent]) -> [DayLogEvent] {
    dayLogNetCompletions(events: events.map(\.core)).map(DayLogEvent.init(core:))
  }

  /// The ids of the dailies ticked off on the logical day containing `date`.
  ///
  /// Netted *within the day*, which is the whole difference between a daily and
  /// a task: un-ticking today can't reach back and blank yesterday's square,
  /// and a tick left un-cancelled at midnight is final.
  public static func completedDailyIds(
    events: [DayLogEvent],
    boundary: DayBoundary,
    on date: Date
  ) -> Set<String> {
    Set(
      dayLogCompletedDailyIds(
        events: events.map(\.core), boundary: boundary.core, onMs: date.dayLogMilliseconds))
  }

  /// Daily ticks per logical day, zero-filled across the whole window, so a
  /// day with nothing ticked keeps its slot on the axis. Dailies only: the
  /// chart belongs to the checklist above it.
  public static func dailyBuckets(
    events: [DayLogEvent],
    boundary: DayBoundary,
    endingOn now: Date,
    days: Int
  ) -> [Bucket] {
    dayLogDailyBuckets(
      events: events.map(\.core), boundary: boundary.core, endingOnMs: now.dayLogMilliseconds,
      days: Int64(days)
    ).map(Bucket.init(core:))
  }

  /// Daily ticks per calendar week, zero-filled, for the year range. Netted
  /// per day first, then rolled up.
  public static func weeklyBuckets(
    events: [DayLogEvent],
    boundary: DayBoundary,
    endingOn now: Date,
    weeks: Int
  ) -> [Bucket] {
    dayLogWeeklyBuckets(
      events: events.map(\.core), boundary: boundary.core, endingOnMs: now.dayLogMilliseconds,
      weeks: Int64(weeks)
    ).map(Bucket.init(core:))
  }

  /// One logical day. Netting runs over the *whole* log, because the reopen
  /// that cancels one of the day's completions may itself land later, and a
  /// completion from any day settles a planned task.
  public static func summary(
    events: [DayLogEvent],
    boundary: DayBoundary,
    on date: Date
  ) -> DaySummary {
    DaySummary(
      core: dayLogSummary(
        events: events.map(\.core), boundary: boundary.core, onMs: date.dayLogMilliseconds))
  }

  /// The logical days that have at least one event, used to decide whether
  /// there is enough history to be worth drawing a chart at all.
  public static func recordedDayCount(events: [DayLogEvent], boundary: DayBoundary) -> Int {
    Int(dayLogRecordedDayCount(events: events.map(\.core), boundary: boundary.core))
  }

  /// Consecutive logical days *before* `now`'s day on which something was
  /// completed or a daily ticked, counting back until the first day with
  /// nothing.
  ///
  /// Excludes today deliberately: the task path classifies its milestone
  /// *before* the close is recorded and the daily path *after*, so the caller
  /// always adds the day it is in the middle of earning:
  /// `streakDays = priorCompletionStreak(...) + 1`.
  public static func priorCompletionStreak(
    events: [DayLogEvent],
    boundary: DayBoundary,
    now: Date
  ) -> Int {
    Int(
      dayLogPriorCompletionStreak(
        events: events.map(\.core), boundary: boundary.core, nowMs: now.dayLogMilliseconds))
  }

  /// The earliest logical day in the log — the "collecting since" date the empty
  /// state shows while history builds up.
  public static func firstRecordedDay(events: [DayLogEvent], boundary: DayBoundary) -> Date? {
    dayLogFirstRecordedDay(events: events.map(\.core), boundary: boundary.core)
      .map(Date.init(dayLogMilliseconds:))
  }
}
