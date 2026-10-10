import Foundation
import TaktCore

extension WorkspaceStore {
  public func loggedWorkTotals() throws -> [String: Int] {
    Dictionary(uniqueKeysWithValues: try Self.mappingCoreErrors { try core.loggedWork() }.map {
      ($0.taskId, Int($0.seconds))
    })
  }

  public func workBlocks(for taskId: String) throws -> [FocusWorkBlock] {
    try Self.mappingCoreErrors { try core.workBlocksForTask(taskId: taskId) }.map(FocusWorkBlock.init)
  }

  /// Uses a half-open interval so midnight entries appear on exactly one day.
  /// Saved titles remain available even after the task is renamed or deleted.
  public func focusWorkBlocks(in interval: DateInterval) throws -> [FocusWorkBlock] {
    try Self.mappingCoreErrors {
      try core.workBlocksBetween(fromMs: interval.start.coreMilliseconds, toMs: interval.end.coreMilliseconds)
    }.map(FocusWorkBlock.init)
  }

  /// When each task in the interval was closed. Lists are left out: closing a
  /// container is bookkeeping, not a unit of work done.
  public func taskCompletions(in interval: DateInterval) throws -> [Date] {
    try Self.mappingCoreErrors {
      try core.taskCompletionsBetween(fromMs: interval.start.coreMilliseconds, toMs: interval.end.coreMilliseconds)
    }.map(Date.init(coreMilliseconds:))
  }

  /// When each task in the interval was added, lists left out as they are
  /// from `taskCompletions(in:)`, so the two can be read against each other.
  public func taskCreations(in interval: DateInterval) throws -> [Date] {
    try Self.mappingCoreErrors {
      try core.taskCreationsBetween(fromMs: interval.start.coreMilliseconds, toMs: interval.end.coreMilliseconds)
    }.map(Date.init(coreMilliseconds:))
  }

  /// The tasks closed since `since`, newest first.
  ///
  /// Lists are left out for the reason `taskCompletions(in:)` leaves them out:
  /// closing a container is bookkeeping, not a unit of work done, and a rail
  /// meant to show what you got through should not be padded with it. Cancelled
  /// tasks are kept — deciding not to do something is a real outcome, and the
  /// caller can tell them apart by `status`.
  public func completedTasks(since: Date, limit: Int = 300) throws -> [WorkspaceTask] {
    try Self.mappingCoreErrors {
      try core.completedTasksSince(sinceMs: since.coreMilliseconds, limit: Int64(limit))
    }.map(WorkspaceTask.init)
  }

  /// Today measured against the week it is part of: the Rust core's
  /// `progress::work_progress`, which reads and sums the rows itself.
  public func workProgress(now: Date = .now, calendar: Calendar = .current) throws -> WorkProgress {
    WorkProgress(
      core: try Self.mappingCoreErrors {
        try core.workProgress(
          nowMs: now.coreMilliseconds, zone: calendar.timeZone.identifier,
          firstWeekday: UInt8(clamping: calendar.firstWeekday))
      })
  }

  public func pauseFocusSession(id: String, now: Date = .now) throws {
    try coreWrite { try core.pauseFocusSession(id: id, nowMs: now.coreMilliseconds) }
  }

  public func resumeFocusSession(id: String, now: Date = .now) throws {
    try coreWrite { try core.resumeFocusSession(id: id, nowMs: now.coreMilliseconds) }
  }

  public func checkpointFocusSession(id: String, now: Date = .now) throws {
    try coreWrite { try core.checkpointFocusSession(id: id, nowMs: now.coreMilliseconds) }
  }

  /// On reopening, retain only checkpointed active seconds. Closed-app time is
  /// never silently credited, and the user explicitly resumes the paused block.
  public func recoverInterruptedFocus() throws {
    try coreWrite { try core.recoverInterruptedFocus() }
  }
}

extension WorkspaceStore {
  /// Resume a queue whose remaining entries were blocked at the last handoff.
  public func resumeEligibleFocusQueue(context: FocusContext, now: Date = .now) throws {
    // The Rust core's `focus::resume_eligible_queue`.
    _ = try coreWrite {
      try core.resumeEligibleFocusQueue(context: context.core, nowMs: now.coreMilliseconds, zone: TimeZone.current.identifier)
    }
  }
}

extension WorkspaceStore {
  public func rebaseFocusClock(id: String, elapsedSeconds: Int, now: Date) throws {
    try coreWrite {
      try core.rebaseFocusClock(id: id, elapsedSeconds: Int64(elapsedSeconds), nowMs: now.coreMilliseconds)
    }
  }
}

extension WorkspaceStore {
  /// Settles whatever was left paused when the app last went away.
  ///
  /// Quitting pauses the running block, so a paused session is the normal
  /// state of a closed app rather than a sign of anything. On the way back
  /// in, a block from a day that is over is closed rather than restored; left
  /// un-settled it reappeared as the running session, on the focus screen and
  /// in the menu bar.
  ///
  /// Crediting is dated at the pause, not at now, so the sitting lands in the
  /// day it happened. The Rust core's `progress::resolve_stale_session` reads
  /// the session, applies `StaleFocusPolicy` and writes the outcome.
  @discardableResult
  public func resolveStaleFocusSession(
    now: Date = .now, boundary: DayBoundary = DayBoundary(), context: FocusContext = FocusContext()
  ) throws -> StaleFocusResolution {
    let outcome = try coreWrite {
      try core.resolveStaleFocusSession(
        nowMs: now.coreMilliseconds, zone: boundary.calendar.timeZone.identifier,
        rolloverHour: UInt8(clamping: boundary.rolloverHour), context: context.core)
    }
    return StaleFocusResolution(core: outcome)
  }
}
