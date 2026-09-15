import Foundation
import GRDB
import PriorityCore

/// Dailies, the contributions logged against them, and the ranking that feeds
/// the focus screen. Split from `WorkspaceStore.swift` only for size; this is
/// the same type and the same database.
extension WorkspaceStore {
  // MARK: - Dailies

  /// Every non-archived daily due on `day`, joined to its task and to that
  /// day's contribution, in display order.
  public func dailies(on day: Date = .now, calendar: Calendar = .current) throws -> [DailyItem] {
    let key = DailyContribution.dayKey(for: day, calendar: calendar)
    return try database.read { db in
      let dailies = try WorkspaceDaily.filter(Column("archivedAt") == nil)
        .order(Column("sortOrder"), Column("createdAt")).fetchAll(db)
      return try dailies.compactMap { daily -> DailyItem? in
        guard daily.isDue(on: day, calendar: calendar),
          let task = try WorkspaceTask.fetchOne(db, key: daily.taskId)
        else { return nil }
        let contribution = try DailyContribution
          .filter(Column("dailyId") == daily.id && Column("dayKey") == key).fetchOne(db)
        return DailyItem(daily: daily, task: task, contribution: contribution)
      }
    }
  }

  /// Every daily regardless of schedule — what a settings editor lists.
  public func allDailies() throws -> [WorkspaceDaily] {
    try database.read { db in
      try WorkspaceDaily.filter(Column("archivedAt") == nil)
        .order(Column("sortOrder"), Column("createdAt")).fetchAll(db)
    }
  }

  public func daily(forTaskId taskId: String) throws -> WorkspaceDaily? {
    try database.read { db in
      try WorkspaceDaily.filter(Column("taskId") == taskId && Column("archivedAt") == nil).fetchOne(db)
    }
  }

  /// Makes `taskId` a daily, or returns the one it already has. Idempotent so
  /// the inspector's toggle can be driven from anywhere without checking first.
  @discardableResult
  public func makeDaily(
    taskId: String,
    weekdays: Set<Int> = Set(1...7),
    intervalDays: Int? = nil,
    targetSeconds: Int? = nil,
    now: Date = .now
  ) throws -> WorkspaceDaily {
    try database.write { db in
      guard try WorkspaceTask.fetchOne(db, key: taskId) != nil else {
        throw WorkspaceStoreError.missingTask
      }
      if var existing = try WorkspaceDaily.filter(Column("taskId") == taskId).fetchOne(db) {
        existing.archivedAt = nil
        existing.targetSeconds = targetSeconds ?? existing.targetSeconds
        existing.updatedAt = now
        try existing.update(db)
        return existing
      }
      let order = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM dailies") ?? 0
      let daily = WorkspaceDaily(
        id: UUID().uuidString, taskId: taskId,
        activeWeekdaysMask: WorkspaceDaily.mask(forWeekdays: weekdays),
        intervalDays: intervalDays, intervalAnchor: intervalDays == nil ? nil : now,
        targetSeconds: targetSeconds, sortOrder: order, archivedAt: nil, createdAt: now, updatedAt: now)
      try daily.insert(db)
      return daily
    }
  }

  /// Archives rather than deletes, so logged contributions keep a parent.
  public func archiveDaily(taskId: String, now: Date = .now) throws {
    try database.write { db in
      guard var daily = try WorkspaceDaily.filter(Column("taskId") == taskId && Column("archivedAt") == nil)
        .fetchOne(db)
      else { return }
      daily.archivedAt = now
      daily.updatedAt = now
      try daily.update(db)
    }
  }

  public func updateDaily(
    id: String, weekdays: Set<Int>? = nil, intervalDays: Int?? = nil, targetSeconds: Int?? = nil, now: Date = .now
  ) throws {
    try database.write { db in
      guard var daily = try WorkspaceDaily.fetchOne(db, key: id) else { return }
      if let weekdays, !weekdays.isEmpty { daily.activeWeekdaysMask = WorkspaceDaily.mask(forWeekdays: weekdays) }
      if let intervalDays {
        daily.intervalDays = intervalDays.map { min(366, max(1, $0)) }
        daily.intervalAnchor = intervalDays == nil ? nil : (daily.intervalAnchor ?? now)
      }
      if let targetSeconds { daily.targetSeconds = targetSeconds }
      daily.updatedAt = now
      try daily.update(db)
    }
  }

  /// Records progress against a daily's task for `day`, accumulating seconds
  /// onto any contribution already logged that day.
  ///
  /// `complete` marks the day's commitment met. Passing `false` with seconds is
  /// how a part-finished focus block is credited without claiming the day.
  @discardableResult
  public func logContribution(
    dailyId: String, seconds: Int = 0, complete: Bool = true, now: Date = .now, calendar: Calendar = .current
  ) throws -> DailyContribution {
    try database.write { db in
      guard let daily = try WorkspaceDaily.fetchOne(db, key: dailyId) else {
        throw WorkspaceStoreError.missingDaily
      }
      return try Self.recordContribution(
        db, daily: daily, seconds: seconds, complete: complete, now: now, calendar: calendar)
    }
  }

  /// Un-ticks a day without discarding the time already logged against it.
  public func clearContribution(dailyId: String, on day: Date = .now, calendar: Calendar = .current) throws {
    let key = DailyContribution.dayKey(for: day, calendar: calendar)
    try database.write { db in
      guard var contribution = try DailyContribution
        .filter(Column("dailyId") == dailyId && Column("dayKey") == key).fetchOne(db)
      else { return }
      contribution.completedAt = nil
      try contribution.update(db)
    }
  }

  /// Contributions for one daily over the last `days` days, oldest first — the
  /// run of days behind a streak.
  public func contributionHistory(
    dailyId: String, days: Int, endingOn day: Date = .now, calendar: Calendar = .current
  ) throws -> [DailyContribution] {
    let keys = (0..<max(1, days)).compactMap { offset -> String? in
      guard let date = calendar.date(byAdding: .day, value: -offset, to: day) else { return nil }
      return DailyContribution.dayKey(for: date, calendar: calendar)
    }
    return try database.read { db in
      try DailyContribution.filter(Column("dailyId") == dailyId && keys.contains(Column("dayKey")))
        .order(Column("dayKey")).fetchAll(db)
    }
  }

  static func dueDaily(
    _ db: Database, taskId: String, on day: Date, calendar: Calendar
  ) throws -> WorkspaceDaily? {
    guard let daily = try WorkspaceDaily.filter(Column("taskId") == taskId && Column("archivedAt") == nil)
      .fetchOne(db)
    else { return nil }
    return daily.isDue(on: day, calendar: calendar) ? daily : nil
  }

  @discardableResult
  static func recordContribution(
    _ db: Database, daily: WorkspaceDaily, seconds: Int, complete: Bool, now: Date, calendar: Calendar
  ) throws -> DailyContribution {
    let key = DailyContribution.dayKey(for: now, calendar: calendar)
    if var existing = try DailyContribution
      .filter(Column("dailyId") == daily.id && Column("dayKey") == key).fetchOne(db)
    {
      existing.secondsLogged += max(0, seconds)
      if complete { existing.completedAt = existing.completedAt ?? now }
      try existing.update(db)
      return existing
    }
    let contribution = DailyContribution(
      id: UUID().uuidString, dailyId: daily.id, taskId: daily.taskId, dayKey: key,
      secondsLogged: max(0, seconds), completedAt: complete ? now : nil, createdAt: now)
    try contribution.insert(db)
    return contribution
  }

  // MARK: - Next up

  /// Every open task that could reasonably be done now, flattened into the
  /// shape `NextUpSelector` scores.
  ///
  /// Tasks with open children are left out: you do not "do" a project, you do
  /// its next leaf, and offering the parent on the focus screen means offering
  /// something that can never be finished in one sitting. Dailies already
  /// contributed to today are excluded rather than scored down, so ticking one
  /// visibly removes it from consideration.
  public func nextUpCandidates(now: Date = .now, calendar: Calendar = .current) throws -> [NextUpCandidate] {
    let dayKey = DailyContribution.dayKey(for: now, calendar: calendar)
    return try database.read { db in
      let archivedListIDs = try String.fetchSet(
        db, sql: "SELECT id FROM task_lists WHERE isArchived")
      let parentIDs = try String.fetchSet(
        db,
        sql: """
          SELECT DISTINCT parentTaskId FROM tasks
          WHERE parentTaskId IS NOT NULL AND status = ?
          """,
        arguments: [TaskStatus.open.rawValue])

      let dailies = try WorkspaceDaily.filter(Column("archivedAt") == nil).fetchAll(db)
      let doneToday = try String.fetchSet(
        db, sql: "SELECT dailyId FROM daily_contributions WHERE dayKey = ? AND completedAt IS NOT NULL",
        arguments: [dayKey])
      let outstandingDailyTaskIDs = Set(
        dailies
          .filter { $0.isDue(on: now, calendar: calendar) && !doneToday.contains($0.id) }
          .map(\.taskId))

      let tasks = try WorkspaceTask.filter(Column("status") == TaskStatus.open.rawValue).fetchAll(db)
      return try tasks.compactMap { task -> NextUpCandidate? in
        guard !archivedListIDs.contains(task.listId), !parentIDs.contains(task.id) else { return nil }
        let metadata = try TaskMetadata.fetchOne(db, key: task.id)
        return NextUpCandidate(
          id: task.id,
          title: task.title,
          isDailyDueToday: outstandingDailyTaskIDs.contains(task.id),
          dueAt: task.dueAt,
          startAt: metadata?.startAt,
          matrixUrgency: metadata?.matrixUrgency,
          matrixImportance: metadata?.matrixImportance,
          priority: metadata?.priority,
          estimateSeconds: task.estimateSeconds,
          kanbanColumn: metadata?.kanbanColumn,
          sortOrder: task.sortOrder,
          createdAt: task.createdAt)
      }
    }
  }

  /// Pushes a task out of consideration until `date` by setting its start time.
  /// This is what "schedule it for later" on the focus screen writes.
  public func scheduleTask(id: String, startAt: Date?, now: Date = .now) throws {
    try database.write { db in
      guard try WorkspaceTask.fetchOne(db, key: id) != nil else {
        throw WorkspaceStoreError.missingTask
      }
      if var metadata = try TaskMetadata.fetchOne(db, key: id) {
        metadata.startAt = startAt
        metadata.updatedAt = now
        try metadata.update(db)
      } else {
        try TaskMetadata(
          taskId: id, priority: nil, startAt: startAt, tagsJSON: "[]", recurrenceRule: nil,
          matrixUrgency: nil, matrixImportance: nil, kanbanColumn: nil, externalLinksJSON: "[]",
          updatedAt: now
        ).insert(db)
      }
    }
  }

  /// Brings the plugin-era dailies across: each becomes a task in a "Habits"
  /// list with a daily attached to it, on the same schedule.
  ///
  /// `progressTaskIDs` are workspace tasks already flagged for daily progress
  /// under the old UserDefaults scheme; they keep their task and simply gain a
  /// daily. Both halves match on identity, so running this twice is a no-op.
  @discardableResult
  public func importLegacyDailies(
    _ legacy: [LegacyDailySeed], progressTaskIDs: [String] = [], now: Date = .now
  ) throws -> Int {
    try database.write { db in
      guard let workspace = try Workspace.fetchOne(db) else { return 0 }
      var imported = 0
      var order = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM dailies") ?? 0

      for taskID in progressTaskIDs {
        guard try WorkspaceTask.fetchOne(db, key: taskID) != nil,
          try WorkspaceDaily.filter(Column("taskId") == taskID).fetchOne(db) == nil
        else { continue }
        try WorkspaceDaily(
          id: UUID().uuidString, taskId: taskID, activeWeekdaysMask: WorkspaceDaily.allWeekdaysMask,
          sortOrder: order, createdAt: now, updatedAt: now
        ).insert(db)
        order += 1
        imported += 1
      }

      let pending = try legacy.filter { seed in
        try WorkspaceDaily.filter(Column("legacyDailyId") == seed.id).fetchOne(db) == nil
      }
      guard !pending.isEmpty else { return imported }

      let habits = try habitsList(db, workspaceId: workspace.id, now: now)
      var taskOrder = try Int.fetchOne(
        db, sql: "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM tasks WHERE listId = ?",
        arguments: [habits.id]) ?? 0

      for seed in pending {
        let task = WorkspaceTask(
          id: UUID().uuidString, listId: habits.id, parentTaskId: nil, title: seed.title, notes: "",
          status: .open, sortOrder: taskOrder, dueAt: nil, estimateSeconds: seed.targetSeconds,
          createdAt: seed.createdAt, updatedAt: now)
        try task.insert(db)
        var daily = WorkspaceDaily(
          id: UUID().uuidString, taskId: task.id,
          activeWeekdaysMask: WorkspaceDaily.mask(forWeekdays: seed.activeWeekdays),
          intervalDays: seed.intervalDays, intervalAnchor: seed.intervalAnchor,
          targetSeconds: seed.targetSeconds, sortOrder: order, archivedAt: seed.archivedAt,
          createdAt: seed.createdAt, updatedAt: now)
        daily.legacyDailyId = seed.id
        try daily.insert(db)
        taskOrder += 1
        order += 1
        imported += 1
      }
      return imported
    }
  }

  func habitsList(_ db: Database, workspaceId: String, now: Date) throws -> TaskList {
    if let existing = try TaskList.filter(Column("workspaceId") == workspaceId && Column("name") == "Habits")
      .fetchOne(db)
    {
      return existing
    }
    let order = try Int.fetchOne(
      db, sql: "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM task_lists WHERE workspaceId = ?",
      arguments: [workspaceId]) ?? 0
    let list = TaskList(
      id: UUID().uuidString, workspaceId: workspaceId, folderId: nil, name: "Habits", colorHex: nil,
      sortOrder: order, isArchived: false, createdAt: now, updatedAt: now)
    try list.insert(db)
    return list
  }
}
