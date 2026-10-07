import Foundation
import GRDB
import TaktCore

extension WorkspaceStore {
  public func activeFocusSession() throws -> FocusSession? {
    try database.read { db in
      try FocusSession.filter(Column("phase") != FocusSessionPhase.finished.rawValue)
        .order(Column("startedAt").desc).fetchOne(db)
    }
  }

  public func focusQueue(for sessionId: String) throws -> [FocusQueueTask] {
    try database.read { db in
      let items = try FocusQueueItem.filter(Column("sessionId") == sessionId)
        .order(Column("sortOrder"), Column("createdAt")).fetchAll(db)
      return try items.compactMap { item in
        guard let task = try WorkspaceTask.fetchOne(db, key: item.taskId), !task.isList else { return nil }
        return FocusQueueTask(item: item, task: task)
      }
    }
  }

  /// `plannedSeconds` is the estimate given on the focus screen. It becomes the
  /// session's work block, so the timer counts towards the number the user
  /// actually committed to rather than a fixed pomodoro they never chose.
  public func startFocusSession(
    taskId: String,
    plannedSeconds: Int? = nil,
    workDurationSeconds: Int = 25 * 60,
    breakDurationSeconds: Int = 5 * 60,
    context: FocusContext? = nil,
    overrideAvailability: Bool = false,
    now: Date = .now
  ) throws -> FocusSession {
    try database.write { db in
      if let active = try FocusSession.filter(Column("phase") != FocusSessionPhase.finished.rawValue).fetchOne(db) {
        return active
      }
      try Self.validateActionableTask(db, id: taskId)
      if let context, !overrideAvailability {
        guard let candidate = try Self.focusCandidates(db, now: now, calendar: .current).first(where: { $0.id == taskId }),
          TaskAvailabilityPolicy.reasons(for: candidate, context: context, now: now).isEmpty else { throw TaskPlanningError.unavailable }
        let chosen = plannedSeconds ?? workDurationSeconds
        guard chosen >= max(60, candidate.minimumBlockSeconds ?? 60),
          !candidate.requiresSingleSitting || chosen >= (candidate.remainingSeconds ?? Int.max),
          context.endsAt.map({ Double(chosen) <= $0.timeIntervalSince(now) }) ?? true else { throw TaskPlanningError.unavailable }
      }
      var session = FocusSession(
        id: UUID().uuidString, startedAt: now, endedAt: nil, phase: .running, activeTaskId: taskId,
        activeTaskStartedAt: now,
        workDurationSeconds: max(60, plannedSeconds ?? workDurationSeconds),
        breakDurationSeconds: max(60, breakDurationSeconds),
        breakEndsAt: nil)
      session.activeBlockId = UUID().uuidString
      session.checkpointAt = now
      let firstItem = FocusQueueItem(
        id: UUID().uuidString, sessionId: session.id, taskId: taskId, sortOrder: 0, state: .queued,
        plannedSeconds: plannedSeconds, completedAt: nil, skippedAt: nil, createdAt: now)
      try session.insert(db)
      try firstItem.insert(db)
      return session
    }
  }

  public func addToFocusQueue(
    sessionId: String, taskId: String, plannedSeconds: Int? = nil, now: Date = .now
  ) throws {
    try database.write { db in
      guard try FocusSession.fetchOne(db, key: sessionId) != nil,
        try WorkspaceTask.fetchOne(db, key: taskId) != nil
      else { throw WorkspaceStoreError.missingTask }
      try Self.validateActionableTask(db, id: taskId)
      if try FocusQueueItem.filter(Column("sessionId") == sessionId && Column("taskId") == taskId)
        .filter(Column("state") == FocusQueueState.queued.rawValue).fetchOne(db) != nil
      {
        return
      }
      let count = try FocusQueueItem.filter(Column("sessionId") == sessionId)
        .fetchCount(db)
      let item = FocusQueueItem(
        id: UUID().uuidString, sessionId: sessionId, taskId: taskId, sortOrder: count, state: .queued,
        plannedSeconds: plannedSeconds, completedAt: nil, skippedAt: nil, createdAt: now)
      try item.insert(db)
    }
  }

  /// What finishing a focus block did to the underlying task. A daily's task
  /// survives the sitting — that is the whole point of modelling a daily as a
  /// contribution — so the caller needs to know which happened before it
  /// reports anything to the user.
  public enum FocusCompletionOutcome: Sendable, Equatable {
    case taskCompleted
    case progressLogged(seconds: Int)
    case contributionLogged(seconds: Int)
  }

  public struct FocusCompletion: Sendable, Equatable {
    public let session: FocusSession
    public let outcome: FocusCompletionOutcome
    /// The points the block earned, or nil when it was finished without a
    /// quality judgement — or took no measurable time.
    public let award: FocusAward?
  }

  /// Finishes the current focus block, crediting `elapsedSeconds` of work.
  ///
  /// When the active task has a daily expected today the task stays open and
  /// the time lands on today's contribution instead. Otherwise the task is
  /// completed, which is what the queue's original behaviour was.
  ///
  /// `qualityMultiplier` is how well the user says the block went. Supplying
  /// one scores the block; leaving it nil finishes the block without a score,
  /// which is what every caller that is not the user pressing Done does.
  @discardableResult
  public func completeActiveFocusTask(
    sessionId: String,
    elapsedSeconds: Int = 0,
    qualityMultiplier: Double? = nil,
    completeTask: Bool = true,
    expectedBlockId: String? = nil,
    context: FocusContext = FocusContext(),
    now: Date = .now,
    calendar: Calendar = .current
  ) throws -> FocusCompletion {
    try journalledWrite(completeTask ? "Complete Task" : "Log Daily Progress") { db in
      guard var session = try FocusSession.fetchOne(db, key: sessionId) else { throw WorkspaceStoreError.noActiveFocusTask }
      if let expectedBlockId, try FocusWorkBlock.fetchOne(db, key: expectedBlockId) != nil {
        return FocusCompletion(session: session, outcome: .progressLogged(seconds: 0), award: nil)
      }
      guard let activeID = session.activeTaskId else { throw WorkspaceStoreError.noActiveFocusTask }
      let blockId = expectedBlockId ?? session.activeBlockId ?? "legacy-\(session.id)/\(activeID)"
      if try FocusWorkBlock.fetchOne(db, key: blockId) != nil {
        return FocusCompletion(session: session, outcome: .progressLogged(seconds: 0), award: nil)
      }
      guard expectedBlockId == nil || expectedBlockId == session.activeBlockId else {
        throw WorkspaceStoreError.noActiveFocusTask
      }
      var outcome = completeTask ? FocusCompletionOutcome.taskCompleted : .progressLogged(seconds: max(0, elapsedSeconds))
      let activeTask = try WorkspaceTask.fetchOne(db, key: activeID)
      let daily = try Self.dueDaily(db, taskId: activeID, on: now, calendar: calendar)
      if let daily {
        let credited = max(0, elapsedSeconds)
        try Self.recordContribution(
          db, daily: daily, seconds: credited,
          complete: completeTask || (daily.targetSeconds.map { target in
            let key = DailyContribution.dayKey(for: now, calendar: calendar)
            let logged = (try? Int.fetchOne(db, sql: "SELECT secondsLogged FROM daily_contributions WHERE dailyId = ? AND dayKey = ?",
                                          arguments: [daily.id, key])) ?? 0
            return target > 0 && logged + credited >= target
          } ?? false), now: now, calendar: calendar)
        outcome = .contributionLogged(seconds: credited)
      } else if completeTask, var task = activeTask {
        let wasOpen = task.completedAt == nil
        task.status = .completed
        task.completedAt = task.completedAt ?? now
        task.updatedAt = now
        try task.update(db)
        if wasOpen {
          try Self.scheduleNextOccurrence(db, after: task, now: now, calendar: calendar)
          try Self.expireHabits(db, sourceTaskId: task.id, now: now)
        }
      }
      var block = FocusWorkBlock(id: blockId, sessionId: session.id, taskId: activeTask?.id,
        taskTitle: activeTask?.title ?? "Deleted task", seconds: max(0, elapsedSeconds), recordedAt: now)
      block.originalTaskId = activeTask?.id
      try block.insert(db)
      var award: FocusAward?
      if let qualityMultiplier, elapsedSeconds > 0 {
        let earned = FocusAward(
          id: blockId, sessionId: sessionId, taskId: activeTask?.id, taskTitle: activeTask?.title ?? "Untitled task",
          seconds: elapsedSeconds, multiplier: qualityMultiplier, awardedAt: now)
        try earned.insert(db)
        award = earned
      }
      if var item = try FocusQueueItem.filter(Column("sessionId") == sessionId && Column("taskId") == activeID)
        .filter(Column("state") == FocusQueueState.queued.rawValue).fetchOne(db)
      {
        item.state = .completed
        item.completedAt = now
        try item.update(db)
      }
      let candidates = try Self.focusCandidates(db, now: now, calendar: calendar)
      let candidateById = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
      let pending = try FocusQueueItem.filter(Column("sessionId") == sessionId)
        .filter(Column("state") == FocusQueueState.queued.rawValue).order(Column("sortOrder")).fetchAll(db)
      let next = pending.first { item in
        guard let task = candidateById[item.taskId] else { return false }
        return TaskAvailabilityPolicy.reasons(for: task, context: context, now: now).isEmpty
      }
      session.activeTaskId = next?.taskId
      session.activeTaskStartedAt = now
      session.accumulatedSeconds = 0; session.pausedAt = nil; session.checkpointAt = now
      session.activeBlockId = next == nil ? nil : UUID().uuidString
      if let next, let candidate = candidateById[next.taskId] {
        session.workDurationSeconds = TaskAvailabilityPolicy.plannedSeconds(for: candidate, requested: next.plannedSeconds, context: context, now: now)
      } else if pending.isEmpty {
        session.phase = .finished
        session.endedAt = now
      } else {
        // Keep the blocked queue available; never fabricate a new running task.
        session.pausedAt = now
      }
      try session.update(db)
      return FocusCompletion(session: session, outcome: outcome, award: award)
    }
  }

  /// Whether a running session that has handed off to nothing — every queued
  /// task was blocked at the last handoff — now has a queued task that is
  /// eligible under `context`. A read, so the app can ask before writing:
  /// `resumeEligibleFocusQueue` is a write whether or not it resumes anything,
  /// and a write re-ranks the day, which asked this again, forever, while the
  /// queue stayed blocked.
  public func hasResumableFocusQueueTask(context: FocusContext, now: Date = .now) throws -> Bool {
    try database.read { db in
      guard let session = try FocusSession.filter(Column("phase") == FocusSessionPhase.running.rawValue)
        .filter(Column("activeTaskId") == nil).fetchOne(db) else { return false }
      let queue = try FocusQueueItem.filter(Column("sessionId") == session.id)
        .filter(Column("state") == FocusQueueState.queued.rawValue).fetchAll(db)
      guard !queue.isEmpty else { return false }
      let candidates = Dictionary(uniqueKeysWithValues: try Self.focusCandidates(db, now: now, calendar: .current).map { ($0.id, $0) })
      return queue.contains { item in
        candidates[item.taskId].map { TaskAvailabilityPolicy.reasons(for: $0, context: context, now: now).isEmpty } ?? false
      }
    }
  }

  public func finishFocusSession(id: String, now: Date = .now) throws {
    try database.write { db in
      guard var session = try FocusSession.fetchOne(db, key: id) else { return }
      session.phase = .finished
      session.endedAt = now
      session.breakEndsAt = nil
      try session.update(db)
    }
  }

  static func nonEmptyName(_ raw: String) throws -> String {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { throw WorkspaceStoreError.emptyName }
    return value
  }

  static func normalizedStrings(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.compactMap { value in
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, seen.insert(trimmed.localizedLowercase).inserted else { return nil }
      return trimmed
    }
  }

  static func decodeStringArray(_ json: String) -> [String] {
    guard let data = json.data(using: .utf8), let values = try? JSONDecoder().decode([String].self, from: data) else {
      return []
    }
    return normalizedStrings(values)
  }

  /// Internal rather than private so `WorkspaceStore+Import.swift` — the same
  /// type, split only for size — can reach it.
}
