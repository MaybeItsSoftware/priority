import Foundation
import TaktCore

/// Putting a task on today, taking it off, and arranging the day by hand.
///
/// "On today" is the Today board column — the one thing in the day a person
/// chose rather than a date put there (see `DayPlanSelector`). Its order is
/// the focus rank, because that is the only order that spans lists: a task's
/// `sortOrder` places it among its siblings, which says nothing about whether
/// the email in the Inbox comes before the report in Work.
extension WorkspaceStore {
  /// Puts each task in the Today column, or takes it out of it.
  ///
  /// Taking a task off today also drops its hand-placed rank. The rank is
  /// its place in the day, and a task that is no longer in the day would
  /// otherwise keep a pinned place on the focus ladder nobody can see the
  /// reason for.
  public func setPlannedForToday(_ planned: Bool, taskIds: [String], now: Date = .now) throws {
    guard !taskIds.isEmpty else { return }
    // The Rust core's `today::set_planned_for_today`.
    try coreWrite { try core.setPlannedForToday(planned: planned, taskIds: taskIds, nowMs: now.coreMilliseconds) }
  }

  /// Writes the day's hand-made order: each task takes its position in
  /// `orderedTaskIds` as its rank.
  ///
  /// Unlike `pinTask`, which nudges one task and leaves the rest to the
  /// ranking, this writes every planned task. The day is a list you arrange,
  /// and an arrangement that rearranged itself whenever a neighbour's score
  /// moved would not be one.
  public func arrangeDay(orderedTaskIds: [String], now: Date = .now) throws {
    // The Rust core's `today::arrange_day`.
    try coreWrite { try core.arrangeDay(orderedTaskIds: orderedTaskIds, nowMs: now.coreMilliseconds) }
  }
}
