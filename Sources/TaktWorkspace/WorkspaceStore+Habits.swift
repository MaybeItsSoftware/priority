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
    guard let taskId, let task = try self.task(id: taskId) else {
      return HabitFormContext(habitTaskId: nil, draft: HabitDraft(title: ""), sourceTitle: nil)
    }
    if let daily = try daily(forTaskId: taskId) {
      let source = try daily.sourceTaskId.flatMap { try self.task(id: $0) }
      let draft = HabitDraft(
        title: task.title, frequency: daily.frequency, dropsAtDayEnd: daily.dropsAtDayEnd,
        estimateSeconds: daily.targetSeconds ?? task.estimateSeconds, expiry: daily.expiry,
        placement: daily.placement ?? .today, sourceTaskId: daily.sourceTaskId)
      return HabitFormContext(habitTaskId: task.id, draft: draft, sourceTitle: source?.title)
    }
    let draft = HabitDraft(title: task.title, sourceTaskId: task.id)
    return HabitFormContext(habitTaskId: nil, draft: draft, sourceTitle: task.title)
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
    guard let daily = try Self.mappingCoreErrors({ try self.core.daily(id: id) }).map(WorkspaceDaily.init) else {
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
    // The Rust core's `habits::reconcile_habits`, outside the journal; it reads
    // first and skips the write when no habit is live.
    try coreWrite { try core.reconcileHabits(nowMs: now.coreMilliseconds, zone: calendar.timeZone.identifier) }
  }
}
