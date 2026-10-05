import Foundation
import GRDB
import TaktCore

/// What the habit form edits: a daily with a column to land in, a rule for
/// when it ends, and whether a missed day is carried.
public struct HabitDraft: Sendable, Equatable {
  public var title: String
  public var frequency: HabitFrequency
  public var dropsAtDayEnd: Bool
  public var estimateSeconds: Int?
  public var expiry: HabitExpiry
  public var placement: HabitPlacement
  /// The task the habit came from. Nil for a standalone habit.
  public var sourceTaskId: String?

  public init(
    title: String, frequency: HabitFrequency = .daily, dropsAtDayEnd: Bool = true,
    estimateSeconds: Int? = nil, expiry: HabitExpiry? = nil, placement: HabitPlacement = .today,
    sourceTaskId: String? = nil
  ) {
    self.title = title
    self.frequency = frequency
    self.dropsAtDayEnd = dropsAtDayEnd
    self.estimateSeconds = estimateSeconds
    self.expiry = expiry ?? (sourceTaskId == nil ? .never : .whenSourceCompleted)
    self.placement = placement
    self.sourceTaskId = sourceTaskId
  }
}

/// What the form opens on: a fresh draft for a new habit, or the stored one.
public struct HabitFormContext: Sendable, Equatable {
  /// The task the habit lives on, when editing one.
  public let habitTaskId: String?
  public var draft: HabitDraft
  /// For "when <source> is done".
  public let sourceTitle: String?

  public init(habitTaskId: String?, draft: HabitDraft, sourceTitle: String?) {
    self.habitTaskId = habitTaskId
    self.draft = draft
    self.sourceTitle = sourceTitle
  }
}

/// Habits: dailies made through the habit form. A habit is still one task
/// with one daily attached — ticking it logs a contribution, never completes
/// the task — so everything that reads dailies reads habits. What a habit
/// adds is a column each appearance lands in, a choice about missed days,
/// and an end. `HabitPolicy` decides all three; this file applies them.
extension WorkspaceStore {
  // MARK: - The form

  /// What the habit form should open on for `taskId`.
  ///
  /// A task that already carries a daily is edited in place, a plain daily
  /// becoming a habit on save. Any other task is the source of a new habit.
  /// No task at all is a standalone habit.
  public func habitFormContext(forTaskId taskId: String?) throws -> HabitFormContext {
    try database.read { db in
      guard let taskId, let task = try WorkspaceTask.fetchOne(db, key: taskId) else {
        return HabitFormContext(habitTaskId: nil, draft: HabitDraft(title: ""), sourceTitle: nil)
      }
      if let daily = try WorkspaceDaily.filter(Column("taskId") == taskId && Column("archivedAt") == nil)
        .fetchOne(db) {
        let source = try daily.sourceTaskId.flatMap { try WorkspaceTask.fetchOne(db, key: $0) }
        let draft = HabitDraft(
          title: task.title, frequency: daily.frequency, dropsAtDayEnd: daily.dropsAtDayEnd,
          estimateSeconds: daily.targetSeconds ?? task.estimateSeconds, expiry: daily.expiry,
          placement: daily.placement ?? .today, sourceTaskId: daily.sourceTaskId)
        return HabitFormContext(habitTaskId: task.id, draft: draft, sourceTitle: source?.title)
      }
      let draft = HabitDraft(title: task.title, sourceTaskId: task.id)
      return HabitFormContext(habitTaskId: nil, draft: draft, sourceTitle: task.title)
    }
  }

  /// Creates a habit, or rewrites the one on `habitTaskId`.
  ///
  /// A new habit is a task in the Habits list — beside the task it came from
  /// rather than under it, so finishing the source is not blocked by an open
  /// child that recurs forever. It lands in its column straight away if it is
  /// due today.
  @discardableResult
  public func saveHabit(
    _ draft: HabitDraft, habitTaskId: String? = nil, now: Date = .now, calendar: Calendar = .current
  ) throws -> WorkspaceDaily {
    let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { throw WorkspaceStoreError.emptyName }
    return try journalledWrite(habitTaskId == nil ? "New Habit" : "Edit Habit") { db in
      let task: WorkspaceTask
      if let habitTaskId {
        guard var existing = try WorkspaceTask.fetchOne(db, key: habitTaskId) else {
          throw WorkspaceStoreError.missingTask
        }
        if existing.title != title || existing.estimateSeconds != draft.estimateSeconds {
          existing.title = title
          existing.estimateSeconds = draft.estimateSeconds
          existing.updatedAt = now
          try existing.update(db)
        }
        task = existing
      } else {
        guard let workspace = try Workspace.fetchOne(db) else { throw WorkspaceStoreError.missingList }
        let habits = try habitsList(db, workspaceId: workspace.id, now: now)
        let order = try Int.fetchOne(
          db, sql: "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM tasks WHERE listId = ? AND parentTaskId IS NULL",
          arguments: [habits.id]) ?? 0
        task = WorkspaceTask(
          id: UUID().uuidString, listId: habits.id, parentTaskId: nil, title: title, notes: "",
          status: .open, sortOrder: order, dueAt: nil, estimateSeconds: draft.estimateSeconds,
          createdAt: now, updatedAt: now)
        try task.insert(db)
      }

      var daily = try Self.makeDailyRecord(db, taskId: task.id, targetSeconds: draft.estimateSeconds, now: now)
      let previousPlacement = daily.placementColumn
      let schedule = draft.frequency.storage
      daily.activeWeekdaysMask = WorkspaceDaily.mask(forWeekdays: schedule.weekdays)
      if daily.intervalDays != schedule.intervalDays || daily.intervalAnchor == nil {
        // A habit is anchored on the day it was made, so "every 3 days" and
        // "weekly" count from then — and so nothing is owed from before it.
        daily.intervalAnchor = calendar.startOfDay(for: daily.intervalAnchor ?? now)
      }
      daily.intervalDays = schedule.intervalDays
      daily.targetSeconds = draft.estimateSeconds
      daily.sourceTaskId = draft.sourceTaskId
      daily.placementColumn = draft.placement.rawValue
      daily.dropsAtDayEnd = draft.dropsAtDayEnd
      daily.expiryRule = draft.expiry.rule
      daily.expiresAt = draft.expiry.date.map { calendar.startOfDay(for: $0) }
      daily.updatedAt = now
      try daily.update(db)

      // Moving a habit to another column takes its card along.
      if let previousPlacement, previousPlacement != daily.placementColumn,
        try Self.kanbanColumn(db, taskId: task.id) == previousPlacement {
        try Self.writeKanbanColumn(db, taskId: task.id, column: nil, now: now)
      }
      _ = try Self.reconcileHabit(db, daily: daily, now: now, calendar: calendar)
      return try WorkspaceDaily.fetchOne(db, key: daily.id) ?? daily
    }
  }

  // MARK: - The engine

  /// Applies every habit's options for `now`: expired habits are archived,
  /// a due appearance is put in its column, and one that is done, dropped at
  /// the end of its day, or no longer due is taken out of it.
  ///
  /// Not an undo step — nobody asked for it, and undoing it would only put a
  /// card back that the next pass takes out again. Returns whether anything
  /// changed, so the caller knows to reload the board.
  @discardableResult
  public func reconcileHabits(now: Date = .now, calendar: Calendar = .current) throws -> Bool {
    let pending = try database.read { db in
      try WorkspaceDaily.filter(Column("archivedAt") == nil && Column("placementColumn") != nil).fetchAll(db)
    }
    guard !pending.isEmpty else { return false }
    return try database.write { db in
      var changed = false
      for daily in pending {
        guard let current = try WorkspaceDaily.fetchOne(db, key: daily.id), !current.isArchived else { continue }
        if try Self.reconcileHabit(db, daily: current, now: now, calendar: calendar) { changed = true }
      }
      return changed
    }
  }

  /// One habit's pass. See `reconcileHabits`.
  static func reconcileHabit(_ db: Database, daily: WorkspaceDaily, now: Date, calendar: Calendar) throws -> Bool {
    guard let placement = daily.placement,
      let task = try WorkspaceTask.fetchOne(db, key: daily.taskId), task.status == .open
    else { return false }
    let rule = daily.habitRule
    let sourceCompleted = try isSourceCompleted(db, daily: daily)
    let current = try kanbanColumn(db, taskId: task.id)
    if HabitPolicy.isExpired(rule, on: now, sourceCompleted: sourceCompleted, calendar: calendar) {
      var archived = daily
      archived.archivedAt = now
      archived.updatedAt = now
      try archived.update(db)
      if current == placement.rawValue { try writeKanbanColumn(db, taskId: task.id, column: nil, now: now) }
      return true
    }
    let appearance = HabitPolicy.appearance(
      rule, on: now, lastDoneDay: try lastDoneDay(db, dailyId: daily.id, calendar: calendar),
      sourceCompleted: sourceCompleted, calendar: calendar)
    guard let target = HabitPolicy.reconciledColumn(current: current, appearance: appearance, placement: placement)
    else { return false }
    try writeKanbanColumn(db, taskId: task.id, column: target, now: now)
    return true
  }

  /// Whether a habit is showing on `day` — scheduled, or carried over from a
  /// missed day it does not drop. What `dailies(on:)` lists.
  static func habitShows(_ db: Database, daily: WorkspaceDaily, on day: Date, calendar: Calendar) throws -> Bool {
    let rule = daily.habitRule
    let sourceCompleted = try isSourceCompleted(db, daily: daily)
    guard !HabitPolicy.isExpired(rule, on: day, sourceCompleted: sourceCompleted, calendar: calendar) else {
      return false
    }
    if HabitPolicy.isScheduled(rule, on: day, calendar: calendar) { return true }
    return HabitPolicy.appearance(
      rule, on: day, lastDoneDay: try lastDoneDay(db, dailyId: daily.id, calendar: calendar),
      sourceCompleted: sourceCompleted, calendar: calendar) != nil
  }

  /// Ends every habit made from `sourceTaskId` that ends with it. Called from
  /// each place a task is closed, inside that write, so undoing the
  /// completion brings the habits back with it.
  static func expireHabits(_ db: Database, sourceTaskId: String, now: Date) throws {
    let habits = try WorkspaceDaily.filter(
      Column("sourceTaskId") == sourceTaskId && Column("archivedAt") == nil
        && Column("expiryRule") == HabitExpiry.whenSourceCompleted.rule
    ).fetchAll(db)
    for var habit in habits {
      habit.archivedAt = now
      habit.updatedAt = now
      try habit.update(db)
      if let column = habit.placementColumn, try kanbanColumn(db, taskId: habit.taskId) == column {
        try writeKanbanColumn(db, taskId: habit.taskId, column: nil, now: now)
      }
    }
  }

  // MARK: - Helpers

  /// A source that is closed or gone has ended.
  private static func isSourceCompleted(_ db: Database, daily: WorkspaceDaily) throws -> Bool {
    guard let sourceId = daily.sourceTaskId else { return false }
    guard let source = try WorkspaceTask.fetchOne(db, key: sourceId) else { return true }
    return source.status != .open
  }

  private static func lastDoneDay(_ db: Database, dailyId: String, calendar: Calendar) throws -> Date? {
    guard let key = try String.fetchOne(
      db, sql: "SELECT MAX(dayKey) FROM daily_contributions WHERE dailyId = ? AND completedAt IS NOT NULL",
      arguments: [dailyId])
    else { return nil }
    let parts = key.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
  }

  static func kanbanColumn(_ db: Database, taskId: String) throws -> String? {
    try String.fetchOne(db, sql: "SELECT kanbanColumn FROM task_metadata WHERE taskId = ?", arguments: [taskId])
  }

  /// Taking a card out of a column also drops its place in the day, as
  /// `setPlannedForToday` does.
  static func writeKanbanColumn(_ db: Database, taskId: String, column: String?, now: Date) throws {
    try db.execute(sql: """
      INSERT INTO task_metadata(taskId, tagsJSON, externalLinksJSON, kanbanColumn, updatedAt)
      VALUES (?, '[]', '[]', ?, ?)
      ON CONFLICT(taskId) DO UPDATE SET
        kanbanColumn = excluded.kanbanColumn,
        focusRank = CASE WHEN excluded.kanbanColumn IS NULL THEN NULL ELSE focusRank END,
        updatedAt = excluded.updatedAt
      """, arguments: [taskId, column, now])
  }
}
