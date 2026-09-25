import Foundation
import GRDB
import PriorityCore

/// Tasks that come round again.
///
/// A task carrying a period rule is not finished when you finish it — it is
/// finished *this time*. Closing one therefore does two things: the occurrence
/// you did is closed for good, so it counts towards the day exactly like any
/// other completed task, and the next one is written as a fresh task dated for
/// when it is next due.
///
/// Scheduling forward rather than reopening the same row is what keeps the
/// history honest. A single row that flips back to open can only ever record
/// the last time it was done, and a week of completions you cannot count is a
/// week that reads as a week of nothing.
///
/// Nothing pushes them into today: the new task carries a start date, and the
/// day already claims whatever starts today. Autoscheduling is that pair, not
/// a third mechanism.
extension WorkspaceStore {
  /// The next occurrence of `task`, if it has a period rule.
  ///
  /// Returns the new task, or nil when the rule is missing or unparseable — an
  /// unreadable rule must not stop a task being completed.
  @discardableResult
  static func scheduleNextOccurrence(
    _ db: Database,
    after task: WorkspaceTask,
    now: Date,
    calendar: Calendar = .current
  ) throws -> WorkspaceTask? {
    guard !task.isList else { return nil }
    guard let metadata = try TaskMetadata.fetchOne(db, key: task.id),
      let rule = metadata.recurrenceRule,
      let schedule = PeriodicSchedule(rule)
    else { return nil }

    // Step from the dates the occurrence actually carried, so "every 3 days"
    // stays on its own rhythm instead of restarting from whenever you got
    // round to it. With neither date, today is the only reference there is.
    func rolled(_ date: Date?) -> Date? {
      date.flatMap { schedule.nextOccurrence(after: $0, notBefore: now, calendar: calendar) }
    }
    let dueAt = rolled(task.dueAt)
    let startAt = rolled(metadata.startAt)
      ?? (dueAt == nil ? schedule.nextOccurrence(after: now, notBefore: now, calendar: calendar) : nil)
    guard startAt != nil || dueAt != nil else { return nil }

    let next = WorkspaceTask(
      id: UUID().uuidString, listId: task.listId, parentTaskId: task.parentTaskId,
      title: task.title, notes: task.notes, status: .open,
      sortOrder: task.sortOrder, dueAt: dueAt, estimateSeconds: task.estimateSeconds,
      sourceSystem: nil, sourceId: nil, itemKind: task.itemKind, isPromoted: task.isPromoted,
      archivedAt: nil, completedAt: nil, createdAt: now, updatedAt: now)
    try next.insert(db)

    // Everything that describes the work carries over; everything that
    // describes *this sitting* does not. A repeat pinned to today's column or
    // to a rung of the ladder would arrive already claiming a place in a day
    // nobody has planned yet.
    var carried = TaskMetadata(
      taskId: next.id, priority: metadata.priority, startAt: startAt,
      tagsJSON: metadata.tagsJSON, recurrenceRule: metadata.recurrenceRule,
      matrixUrgency: metadata.matrixUrgency, matrixImportance: metadata.matrixImportance,
      kanbanColumn: nil, externalLinksJSON: metadata.externalLinksJSON, focusRank: nil,
      updatedAt: now)
    carried.planningJSON = metadata.planningJSON
    try carried.insert(db)

    // The finished occurrence keeps its place; the next one follows it.
    var siblings = try WorkspaceTask
      .filter(Column("listId") == task.listId && Column("parentTaskId") == task.parentTaskId)
      .order(Column("sortOrder"), Column("createdAt"), Column("id")).fetchAll(db)
    siblings.removeAll { $0.id == next.id }
    if let index = siblings.firstIndex(where: { $0.id == task.id }) {
      siblings.insert(next, at: index + 1)
      try Self.persistTaskOrder(siblings, db: db, now: now)
    }
    return try WorkspaceTask.fetchOne(db, key: next.id) ?? next
  }

  /// Whether a task repeats, and how often — for anything that wants to say so
  /// without re-reading the rule itself.
  public func periodicSchedule(for taskId: String) throws -> PeriodicSchedule? {
    try database.read { db in
      guard let metadata = try TaskMetadata.fetchOne(db, key: taskId),
        let rule = metadata.recurrenceRule
      else { return nil }
      return PeriodicSchedule(rule)
    }
  }

  /// When a task is scheduled to be begun, if anything scheduled it.
  public func startAt(for taskId: String) throws -> Date? {
    try database.read { db in try TaskMetadata.fetchOne(db, key: taskId)?.startAt }
  }
}
