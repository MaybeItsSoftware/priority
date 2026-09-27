import Foundation
import GRDB
import PriorityCore

extension WorkspaceStore {
  public func loggedWorkTotals() throws -> [String: Int] {
    try database.read { db in
      Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: """
        SELECT COALESCE(taskId, originalTaskId) AS taskId, SUM(seconds) AS seconds
        FROM focus_work_blocks WHERE COALESCE(taskId, originalTaskId) IS NOT NULL
        GROUP BY COALESCE(taskId, originalTaskId)
        """).map { row -> (String, Int) in (row["taskId"], row["seconds"]) })
    }
  }

  public func workBlocks(for taskId: String) throws -> [FocusWorkBlock] {
    try database.read { db in
      try FocusWorkBlock.filter(Column("taskId") == taskId || Column("originalTaskId") == taskId).order(Column("recordedAt")).fetchAll(db)
    }
  }

  /// Uses a half-open interval so midnight entries appear on exactly one day.
  /// Saved titles remain available even after the task is renamed or deleted.
  public func focusWorkBlocks(in interval: DateInterval) throws -> [FocusWorkBlock] {
    try database.read { db in
      try FocusWorkBlock.filter(Column("recordedAt") >= interval.start && Column("recordedAt") < interval.end)
        .order(Column("recordedAt"), Column("id")).fetchAll(db)
    }
  }

  /// When each task in the interval was closed. Lists are left out: closing a
  /// container is bookkeeping, not a unit of work done.
  public func taskCompletions(in interval: DateInterval) throws -> [Date] {
    try database.read { db in
      try Date.fetchAll(db, sql: """
        SELECT completedAt FROM tasks
        WHERE completedAt IS NOT NULL AND completedAt >= ? AND completedAt < ?
          AND COALESCE(itemKind, 'task') <> 'list'
        ORDER BY completedAt
        """, arguments: [interval.start, interval.end])
    }
  }

  /// The tasks closed since `since`, newest first.
  ///
  /// Lists are left out for the reason `taskCompletions(in:)` leaves them out:
  /// closing a container is bookkeeping, not a unit of work done, and a rail
  /// meant to show what you got through should not be padded with it. Cancelled
  /// tasks are kept — deciding not to do something is a real outcome, and the
  /// caller can tell them apart by `status`.
  public func completedTasks(since: Date, limit: Int = 300) throws -> [WorkspaceTask] {
    try database.read { db in
      try WorkspaceTask
        .filter(Column("completedAt") != nil && Column("completedAt") >= since)
        .filter(sql: "COALESCE(itemKind, 'task') <> 'list'")
        .order(Column("completedAt").desc, Column("id").desc)
        .limit(limit)
        .fetchAll(db)
    }
  }

  /// Today measured against the week it is part of.
  public func workProgress(now: Date = .now, calendar: Calendar = .current) throws -> WorkProgress {
    let start = WorkProgressSummary.startOfWeek(containing: now, calendar: calendar)
    let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
    guard end > start else { return .empty }
    let interval = DateInterval(start: start, end: end)
    return WorkProgressSummary.summarise(
      completions: try taskCompletions(in: interval),
      blocks: try focusWorkBlocks(in: interval).map { (seconds: $0.seconds, recordedAt: $0.recordedAt) },
      now: now, calendar: calendar)
  }

  public func pauseFocusSession(id: String, now: Date = .now) throws {
    try database.write { db in
      guard var session = try FocusSession.fetchOne(db, key: id), session.phase == .running,
        session.pausedAt == nil else { return }
      session.accumulatedSeconds = session.elapsedSeconds(now: now)
      session.pausedAt = now; session.checkpointAt = now
      try session.update(db)
    }
  }

  public func resumeFocusSession(id: String, now: Date = .now) throws {
    try database.write { db in
      guard var session = try FocusSession.fetchOne(db, key: id), session.phase == .running,
        session.pausedAt != nil else { return }
      session.pausedAt = nil; session.activeTaskStartedAt = now; session.checkpointAt = now
      try session.update(db)
    }
  }

  public func checkpointFocusSession(id: String, now: Date = .now) throws {
    try database.write { db in
      guard var session = try FocusSession.fetchOne(db, key: id), session.phase == .running,
        session.pausedAt == nil else { return }
      session.accumulatedSeconds = session.elapsedSeconds(now: now)
      session.activeTaskStartedAt = now; session.checkpointAt = now
      try session.update(db)
    }
  }

  /// On reopening, retain only checkpointed active seconds. Closed-app time is
  /// never silently credited, and the user explicitly resumes the paused block.
  public func recoverInterruptedFocus() throws {
    try database.write { db in
      for var session in try FocusSession.filter(Column("phase") == FocusSessionPhase.running.rawValue).fetchAll(db) {
        guard session.pausedAt == nil else { continue }
        session.pausedAt = session.checkpointAt ?? session.activeTaskStartedAt
        if session.accumulatedSeconds == nil { session.accumulatedSeconds = 0 }
        try session.update(db)
      }
    }
  }
}

extension WorkspaceStore {
  /// Resume a queue whose remaining entries were blocked at the last handoff.
  public func resumeEligibleFocusQueue(context: FocusContext, now: Date = .now) throws {
    try database.write { db in
      guard var session = try FocusSession.filter(Column("phase") == FocusSessionPhase.running.rawValue)
        .filter(Column("activeTaskId") == nil).fetchOne(db) else { return }
      let candidates = Dictionary(uniqueKeysWithValues: try Self.focusCandidates(db, now: now, calendar: .current).map { ($0.id, $0) })
      let queue = try FocusQueueItem.filter(Column("sessionId") == session.id)
        .filter(Column("state") == FocusQueueState.queued.rawValue).order(Column("sortOrder")).fetchAll(db)
      guard let next = queue.first(where: { item in
        candidates[item.taskId].map { TaskAvailabilityPolicy.reasons(for: $0, context: context, now: now).isEmpty } ?? false
      }), let task = candidates[next.taskId] else { return }
      session.workDurationSeconds = TaskAvailabilityPolicy.plannedSeconds(for: task, requested: next.plannedSeconds, context: context, now: now)
      session.activeTaskId = task.id; session.activeTaskStartedAt = now
      session.activeBlockId = UUID().uuidString; session.accumulatedSeconds = 0
      session.pausedAt = nil; session.checkpointAt = now
      try session.update(db)
    }
  }
}

extension WorkspaceStore {
  public func rebaseFocusClock(id: String, elapsedSeconds: Int, now: Date) throws {
    try database.write { db in
      guard var session = try FocusSession.fetchOne(db, key: id), session.phase == .running,
        session.pausedAt == nil else { return }
      session.accumulatedSeconds = max(0, elapsedSeconds)
      session.activeTaskStartedAt = now; session.checkpointAt = now
      try session.update(db)
    }
  }
}

extension WorkspaceStore {
  /// Settles whatever was left paused when the app last went away.
  ///
  /// Quitting pauses the running block, so a paused session is the normal
  /// state of a closed app rather than a sign of anything. What was missing was
  /// the other half: on the way back in, a block from a day that is over gets
  /// closed rather than restored. Left un-settled it reappeared as the running
  /// session — on the focus screen, and in the menu bar, as the thing you were
  /// supposedly in the middle of.
  ///
  /// Crediting is dated at the pause, not at now, so the sitting lands in the
  /// day it happened; the timeline for that day is where it shows up.
  /// `StaleFocusPolicy` holds the decision and is tested on its own.
  @discardableResult
  public func resolveStaleFocusSession(
    now: Date = .now, boundary: DayBoundary = DayBoundary(), context: FocusContext = FocusContext()
  ) throws -> StaleFocusResolution {
    guard let session = try activeFocusSession() else { return .keep }
    let resolution = StaleFocusPolicy.resolution(
      pausedAt: session.pausedAt,
      accumulatedSeconds: max(0, session.accumulatedSeconds ?? 0),
      hasActiveTask: session.activeTaskId != nil,
      now: now, boundary: boundary)
    let endedAt = session.pausedAt ?? now
    switch resolution {
    case .keep:
      break
    case .close:
      // `completeTask: false` — the block ran out of day, which says nothing
      // about whether the task is done.
      try completeActiveFocusTask(
        sessionId: session.id, elapsedSeconds: max(0, session.accumulatedSeconds ?? 0),
        completeTask: false, expectedBlockId: session.activeBlockId, context: context, now: endedAt)
      try finishFocusSession(id: session.id, now: endedAt)
    case .discard:
      try finishFocusSession(id: session.id, now: endedAt)
    }
    return resolution
  }
}
