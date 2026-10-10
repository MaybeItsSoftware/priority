import Foundation
import TaktRustCore

// The day log's types as the Rust core (`core/src/day_log.rs`) takes and
// returns them. The format, the logical days and every projection are the
// core's; these only translate.

extension Date {
  /// Milliseconds since 1970, rounded down: the file holds whole seconds and
  /// `JSONEncoder` rounds down to them, so the core must not round up.
  var dayLogMilliseconds: Int64 { Int64((timeIntervalSince1970 * 1000).rounded(.down)) }

  init(dayLogMilliseconds ms: Int64) {
    self.init(timeIntervalSince1970: Double(ms) / 1000)
  }
}

extension DayLogEventKind {
  var core: DayLogRecordKind {
    switch self {
    case .completed: return .completed
    case .reopened: return .reopened
    case .invalidated: return .invalidated
    case .focusSessionEnded: return .focusSessionEnded
    case .deferred: return .deferred
    case .planSnapshot: return .planSnapshot
    case .dailyCompleted: return .dailyCompleted
    case .dailyUncompleted: return .dailyUncompleted
    }
  }

  init(core: DayLogRecordKind) {
    switch core {
    case .completed: self = .completed
    case .reopened: self = .reopened
    case .invalidated: self = .invalidated
    case .focusSessionEnded: self = .focusSessionEnded
    case .deferred: self = .deferred
    case .planSnapshot: self = .planSnapshot
    case .dailyCompleted: self = .dailyCompleted
    case .dailyUncompleted: self = .dailyUncompleted
    }
  }
}

extension DayLogEvent {
  var core: DayLogRecord {
    DayLogRecord(
      kind: kind.core,
      atMs: at.dayLogMilliseconds,
      taskId: Int64(taskId),
      title: title,
      durationSeconds: durationSeconds.map(Int64.init),
      plannedTaskIds: plannedTaskIds?.map(Int64.init),
      dailyId: dailyId
    )
  }

  init(core: DayLogRecord) {
    self.init(
      kind: DayLogEventKind(core: core.kind),
      at: Date(dayLogMilliseconds: core.atMs),
      taskId: Int(core.taskId),
      title: core.title,
      durationSeconds: core.durationSeconds.map(Int.init),
      plannedTaskIds: core.plannedTaskIds?.map(Int.init),
      dailyId: core.dailyId
    )
  }
}

extension DayBoundary {
  /// The zone and first weekday come from `calendar`; the core counts days
  /// in the Gregorian calendar whatever `calendar` is, because a day key is
  /// a stored identifier, not a label.
  var core: DayLogBoundary {
    DayLogBoundary(
      rolloverHour: Int32(rolloverHour),
      zone: calendar.timeZone.identifier,
      firstWeekday: UInt8(clamping: calendar.firstWeekday)
    )
  }
}

extension DayLogAggregator.Bucket {
  init(core: DayLogBucket) {
    self.init(day: Date(dayLogMilliseconds: core.dayMs), key: core.key, completed: Int(core.completed))
  }
}

extension DayLogAggregator.DaySummary {
  init(core: DayLogDay) {
    self.init(
      key: core.key,
      day: Date(dayLogMilliseconds: core.dayMs),
      completed: core.completed.map(DayLogEvent.init(core:)),
      plannedTaskIds: core.plannedTaskIds.map(Int.init),
      unfinishedTaskIds: core.unfinishedTaskIds.map(Int.init),
      deferredTaskIds: core.deferredTaskIds.map(Int.init),
      invalidatedTaskIds: core.invalidatedTaskIds.map(Int.init),
      focusSeconds: Int(core.focusSeconds),
      completedDailyIds: Set(core.completedDailyIds)
    )
  }

  var core: DayLogDay {
    DayLogDay(
      key: key,
      dayMs: day.dayLogMilliseconds,
      completed: completed.map(\.core),
      plannedTaskIds: plannedTaskIds.map(Int64.init),
      unfinishedTaskIds: unfinishedTaskIds.map(Int64.init),
      deferredTaskIds: deferredTaskIds.map(Int64.init),
      invalidatedTaskIds: invalidatedTaskIds.map(Int64.init),
      focusSeconds: Int64(focusSeconds),
      completedDailyIds: completedDailyIds.sorted()
    )
  }
}

/// The day log held in the core, read from and appended to its file there,
/// so each projection is one call rather than the whole history crossing the
/// boundary for every one. What the Daily plugin keeps; `DayLogAggregator`'s
/// array-taking functions are for callers that only have an array.
public final class DayLogHistory: @unchecked Sendable {
  public let fileURL: URL
  private let log: CoreDayLog

  public init(directoryURL: URL, fileName: String = "daylog.jsonl") {
    fileURL = directoryURL.appendingPathComponent(fileName)
    log = CoreDayLog.open(path: fileURL.path)
  }

  /// Every event, in file order. Crosses the boundary one event at a time,
  /// so it is for inspection, not for a projection.
  public var events: [DayLogEvent] { log.events().map(DayLogEvent.init(core:)) }

  public var eventCount: Int { Int(log.eventCount()) }

  /// Rereads the file, returning whether it differed from what was held.
  @discardableResult
  public func reload() -> Bool { log.reload() }

  /// Holds `event` and appends it to the file. If the write fails the event
  /// is still held, so the session stays right; the error says the line is
  /// not on disk.
  public func record(_ event: DayLogEvent) throws {
    do {
      try log.record(event: event.core)
    } catch {
      throw DayLogFileStore.StoreError.writeFailed(underlying: error)
    }
  }

  public func summary(boundary: DayBoundary, on date: Date) -> DayLogAggregator.DaySummary {
    DayLogAggregator.DaySummary(core: log.summary(boundary: boundary.core, onMs: date.dayLogMilliseconds))
  }

  public func completedDailyIds(boundary: DayBoundary, on date: Date) -> Set<String> {
    Set(log.completedDailyIds(boundary: boundary.core, onMs: date.dayLogMilliseconds))
  }

  public func dailyBuckets(boundary: DayBoundary, endingOn now: Date, days: Int) -> [DayLogAggregator.Bucket] {
    log.dailyBuckets(boundary: boundary.core, endingOnMs: now.dayLogMilliseconds, days: Int64(days))
      .map(DayLogAggregator.Bucket.init(core:))
  }

  public func weeklyBuckets(boundary: DayBoundary, endingOn now: Date, weeks: Int) -> [DayLogAggregator.Bucket] {
    log.weeklyBuckets(boundary: boundary.core, endingOnMs: now.dayLogMilliseconds, weeks: Int64(weeks))
      .map(DayLogAggregator.Bucket.init(core:))
  }

  public func recordedDayCount(boundary: DayBoundary) -> Int {
    Int(log.recordedDayCount(boundary: boundary.core))
  }

  public func firstRecordedDay(boundary: DayBoundary) -> Date? {
    log.firstRecordedDay(boundary: boundary.core).map(Date.init(dayLogMilliseconds:))
  }

  public func priorCompletionStreak(boundary: DayBoundary, now: Date) -> Int {
    Int(log.priorCompletionStreak(boundary: boundary.core, nowMs: now.dayLogMilliseconds))
  }
}
