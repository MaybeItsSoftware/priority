import Foundation
import GRDB
import TaktCore

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
        let shows = daily.isHabit
          ? try Self.habitShows(db, daily: daily, on: day, calendar: calendar)
          : daily.isDue(on: day, calendar: calendar)
        guard shows,
          let task = try WorkspaceTask.fetchOne(db, key: daily.taskId), !task.isList
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
    try journalledWrite("Make Daily") { db in
      try Self.makeDailyRecord(db, taskId: taskId, weekdays: weekdays, intervalDays: intervalDays,
                               targetSeconds: targetSeconds, now: now)
    }
  }

  static func makeDailyRecord(
    _ db: Database, taskId: String, weekdays: Set<Int> = Set(1...7), intervalDays: Int? = nil,
    targetSeconds: Int?, now: Date
  ) throws -> WorkspaceDaily {
    guard try WorkspaceTask.fetchOne(db, key: taskId) != nil else { throw WorkspaceStoreError.missingTask }
    if var existing = try WorkspaceDaily.filter(Column("taskId") == taskId).fetchOne(db) {
      let target = targetSeconds ?? existing.targetSeconds
      if existing.archivedAt != nil || existing.targetSeconds != target {
        existing.archivedAt = nil
        existing.targetSeconds = target
        existing.updatedAt = now
        try existing.update(db)
      }
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

  /// Archives rather than deletes, so logged contributions keep a parent.
  public func archiveDaily(taskId: String, now: Date = .now) throws {
    try journalledWrite("Archive Daily") { db in
      try Self.archiveDailyRecord(db, taskId: taskId, now: now)
    }
  }

  static func archiveDailyRecord(_ db: Database, taskId: String, now: Date) throws {
    guard var daily = try WorkspaceDaily.filter(Column("taskId") == taskId && Column("archivedAt") == nil)
      .fetchOne(db) else { return }
    daily.archivedAt = now
    daily.updatedAt = now
    try daily.update(db)
  }

  public func updateDaily(
    id: String, weekdays: Set<Int>? = nil, intervalDays: Int?? = nil, targetSeconds: Int?? = nil, now: Date = .now
  ) throws {
    try journalledWrite("Edit Daily") { db in
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
    try journalledWrite("Log Daily") { db in
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
    try journalledWrite("Clear Daily") { db in
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

  // MARK: - Completion context

  /// What a celebration needs to know about today, in one read.
  ///
  /// Both numbers are questions about *today* rather than about the task being
  /// completed, which is why they are fetched together: asking twice invites
  /// the two halves to disagree about where the day boundary fell.
  public struct CompletionContext: Sendable, Equatable {
    /// How many things have already been finished today, this one included.
    /// 1 means "the first thing today", which is what earns the streak note.
    public let ordinalToday: Int
    /// Consecutive days ending today on which something was finished.
    public let streakDays: Int

    public init(ordinalToday: Int, streakDays: Int) {
      self.ordinalToday = ordinalToday
      self.streakDays = streakDays
    }
  }

  public func completionContext(now: Date = .now, calendar: Calendar = .current) throws -> CompletionContext {
    try database.read { db in
      let today = calendar.startOfDay(for: now)
      let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now
      let tasksToday = try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM tasks WHERE status = ? AND updatedAt >= ? AND updatedAt < ?",
        arguments: [TaskStatus.completed.rawValue, today, tomorrow]) ?? 0
      let contributionsToday = try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM daily_contributions WHERE dayKey = ? AND completedAt IS NOT NULL",
        arguments: [DailyContribution.dayKey(for: now, calendar: calendar)]) ?? 0
      // Counting the completion about to happen, so the first of the day is 1.
      let ordinal = tasksToday + contributionsToday + 1

      // Walk back a day at a time until a day has nothing in it. Bounded at a
      // year: past that the number stops meaning anything and the scan stops
      // being free.
      var streak = 0
      for offset in 0..<366 {
        guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { break }
        let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        let finished = try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM tasks WHERE status = ? AND updatedAt >= ? AND updatedAt < ?",
          arguments: [TaskStatus.completed.rawValue, day, next]) ?? 0
        let ticked = try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM daily_contributions WHERE dayKey = ? AND completedAt IS NOT NULL",
          arguments: [DailyContribution.dayKey(for: day, calendar: calendar)]) ?? 0
        if finished + ticked > 0 {
          streak += 1
        } else if offset == 0 {
          // Today being empty does not break a streak that is about to be
          // extended by the completion we are describing.
          streak += 1
        } else {
          break
        }
      }
      return CompletionContext(ordinalToday: ordinal, streakDays: streak)
    }
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
    try database.read { try Self.focusCandidates($0, now: now, calendar: calendar) }
  }

  static func focusCandidates(_ db: Database, now: Date, calendar: Calendar) throws -> [NextUpCandidate] {
    let dayKey = DailyContribution.dayKey(for: now, calendar: calendar)
    let archived = try String.fetchSet(db, sql: "SELECT id FROM task_lists WHERE isArchived OR completedAt IS NOT NULL")
    let allTasks = try WorkspaceTask.fetchAll(db)
    let inactive = Self.inactiveContainerItems(allTasks)
    let wrappers = try String.fetchSet(db, sql: "SELECT visibleRootTaskId FROM task_lists WHERE visibleRootTaskId IS NOT NULL")
    let parents = try String.fetchSet(db, sql: "SELECT DISTINCT parentTaskId FROM tasks WHERE parentTaskId IS NOT NULL AND status = 'open'")
    let metadata = Dictionary(uniqueKeysWithValues: try TaskMetadata.fetchAll(db).map { ($0.taskId, $0) })
    let dailies = Dictionary(try WorkspaceDaily.filter(Column("archivedAt") == nil).fetchAll(db)
      .map { ($0.taskId, $0) }, uniquingKeysWith: { first, _ in first })
    let contributions = Dictionary(uniqueKeysWithValues: try DailyContribution.filter(Column("dayKey") == dayKey)
      .fetchAll(db).map { ($0.dailyId, $0) })
    let work = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db,
      sql: """
        SELECT COALESCE(taskId, originalTaskId) AS taskId, SUM(seconds) AS seconds
        FROM focus_work_blocks WHERE COALESCE(taskId, originalTaskId) IS NOT NULL
        GROUP BY COALESCE(taskId, originalTaskId)
        """)
      .map { row -> (String, Int) in (row["taskId"], row["seconds"]) })
    return try allTasks.filter { $0.status == .open }.compactMap { task in
      guard !task.isList, !inactive.contains(task.id), !wrappers.contains(task.id),
        !archived.contains(task.listId), !parents.contains(task.id) else { return nil }
      let record = metadata[task.id]
      let plan = try planning(record)
      let daily = dailies[task.id]
      let contribution = daily.flatMap { contributions[$0.id] }
      var dailyUnavailable: TaskUnavailableReason?
      if let daily {
        let shows = daily.isHabit
          ? try habitShows(db, daily: daily, on: now, calendar: calendar)
          : daily.isDue(on: now, calendar: calendar)
        if !shows {
          dailyUnavailable = .dailyNotScheduled
        } else if contribution?.completedAt != nil ||
          (daily.targetSeconds.map { $0 > 0 && (contribution?.secondsLogged ?? 0) >= $0 } ?? false) {
          dailyUnavailable = .dailyAlreadyMet
        }
        // A completed habit can disappear; a task with a deadline must remain
        // visible among blocked urgent work even when its daily is unavailable.
        if dailyUnavailable != nil && task.dueAt == nil && plan?.dueDate == nil { return nil }
      }
      return NextUpCandidate(id: task.id, title: task.title, isDailyDueToday: daily != nil && dailyUnavailable == nil,
        dueAt: task.dueAt, startAt: record?.startAt, matrixUrgency: record?.matrixUrgency,
        matrixImportance: record?.matrixImportance, priority: record?.priority,
        estimateSeconds: task.estimateSeconds, kanbanColumn: record?.kanbanColumn,
        focusRank: record?.focusRank, sortOrder: task.sortOrder, createdAt: task.createdAt,
        dueDate: plan?.dueDate, requirementGroups: plan?.requirementGroups ?? [], loggedSeconds: work[task.id] ?? 0,
        minimumBlockSeconds: plan?.minimumBlockSeconds, requiresSingleSitting: plan?.requiresSingleSitting == true,
        dailyRemainingSeconds: daily?.targetSeconds.map { max(0, $0 - (contribution?.secondsLogged ?? 0)) },
        dailyUnavailable: dailyUnavailable)
    }
  }

  /// Writes a hand-arranged focus order: every task in `orderedTaskIDs` takes
  /// its position in that array as its rank.
  ///
  /// The whole visible order is written, not just the task that moved. Ranking
  /// one task by hand while its neighbours keep floating on score produces an
  /// order that rearranges itself the moment anything changes, which is the
  /// opposite of what dragging something into place asks for.
  /// Pins one task to `index` in the ladder, leaving every other task to be
  /// ordered by score around it.
  ///
  /// Deliberately one task rather than the whole visible order. Writing the
  /// entire ladder is what froze it: every task acquired a rank from a single
  /// nudge, after which nothing could ever be re-ranked again.
  public func pinTask(id taskId: String, atIndex index: Int, now: Date = .now) throws {
    try journalledWrite("Pin Task") { db in
      guard try WorkspaceTask.fetchOne(db, key: taskId) != nil else {
        throw WorkspaceStoreError.missingTask
      }
      let rank = max(0, index)
      if var metadata = try TaskMetadata.fetchOne(db, key: taskId) {
        metadata.focusRank = rank
        metadata.updatedAt = now
        try metadata.update(db)
      } else {
        try TaskMetadata(
          taskId: taskId, priority: nil, startAt: nil, tagsJSON: "[]", recurrenceRule: nil,
          matrixUrgency: nil, matrixImportance: nil, kanbanColumn: nil, externalLinksJSON: "[]",
          focusRank: rank, updatedAt: now
        ).insert(db)
      }
    }
  }

  /// Releases one task back to the ranking.
  public func unpinTask(id taskId: String, now: Date = .now) throws {
    try journalledWrite("Unpin Task") { db in
      guard var metadata = try TaskMetadata.fetchOne(db, key: taskId) else { return }
      metadata.focusRank = nil
      metadata.updatedAt = now
      try metadata.update(db)
    }
  }

  /// Hands the ladder back to the ranking.
  public func clearFocusOrder(now: Date = .now) throws {
    try journalledWrite("Clear Focus Order") { db in
      try db.execute(
        sql: "UPDATE task_metadata SET focusRank = NULL, updatedAt = ? WHERE focusRank IS NOT NULL",
        arguments: [now])
    }
  }

  public func hasManualFocusOrder() throws -> Bool {
    try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task_metadata WHERE focusRank IS NOT NULL") ?? 0 > 0
    }
  }

  /// Pushes a task out of consideration until `date` by setting its start time.
  /// This is what "schedule it for later" on the focus screen writes.
  public func scheduleTask(id: String, startAt: Date?, now: Date = .now) throws {
    try journalledWrite("Schedule Task") { db in
      let previous = try Self.taskEditorSnapshot(db, taskId: id)
      var edit = previous
      var plan = edit.planning ?? TaskPlanning()
      plan.startAt = startAt
      edit.planning = plan.normalized
      try Self.updatePlanning(db, edit: edit, previous: previous.planning, previousDueAt: previous.dueAt, now: now)
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
    let id = HabitPolicy.habitsListId(workspaceId: workspaceId)
    if let existing = try TaskList.fetchOne(db, key: id) { return existing }
    if let existing = try TaskList.filter(
      Column("workspaceId") == workspaceId && Column("name") == HabitPolicy.habitsListName
    ).fetchOne(db) {
      return existing
    }
    let order = try Int.fetchOne(
      db, sql: "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM task_lists WHERE workspaceId = ?",
      arguments: [workspaceId]) ?? 0
    let list = TaskList(
      // Derived rather than random: another device making it too makes the
      // same row, and sync merges the two.
      id: id, workspaceId: workspaceId, folderId: nil, name: HabitPolicy.habitsListName, colorHex: nil,
      sortOrder: order, isArchived: false, createdAt: now, updatedAt: now)
    try list.insert(db)
    return list
  }
}
