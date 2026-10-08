import Foundation
import GRDB
import TaktRustCore
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
    // The Rust core's `habits::save_habit`, with the schedule as a daily stores it.
    let schedule = draft.frequency.storage
    let weekdays = schedule.weekdays.sorted().map { UInt32(clamping: $0) }
    let interval = schedule.intervalDays.map { Int64($0) }
    let estimate = draft.estimateSeconds.map { Int64($0) }
    let core = TaktRustCore.HabitDraft(
      title: draft.title, weekdays: weekdays, intervalDays: interval, dropsAtDayEnd: draft.dropsAtDayEnd,
      estimateSeconds: estimate, expiryRule: draft.expiry.rule, expiresAtMs: draft.expiry.date?.coreMilliseconds,
      placement: draft.placement.rawValue, sourceTaskId: draft.sourceTaskId)
    let id = try coreWrite {
      try self.core.saveHabit(
        draft: core, habitTaskId: habitTaskId, nowMs: now.coreMilliseconds, zone: calendar.timeZone.identifier)
    }
    guard let daily = try database.read({ db in try WorkspaceDaily.fetchOne(db, key: id) }) else {
      throw WorkspaceStoreError.missingDaily
    }
    return daily
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
      try WorkspaceDaily.filter(Column("archivedAt") == nil && Column("placementColumn") != nil).fetchCount(db)
    }
    guard pending > 0 else { return false }
    // The Rust core's `habits::reconcile_habits`, outside the journal.
    return try coreWrite { try core.reconcileHabits(nowMs: now.coreMilliseconds, zone: calendar.timeZone.identifier) }
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
