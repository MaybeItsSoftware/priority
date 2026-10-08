import Foundation
import TaktRustCore
import TaktCore

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

  /// Whether a task repeats, and how often — for anything that wants to say so
  /// without re-reading the rule itself.
  public func periodicSchedule(for taskId: String) throws -> PeriodicSchedule? {
    guard let rule = try Self.mappingCoreErrors({ try core.metadata(taskId: taskId) })?.recurrenceRule else {
      return nil
    }
    return PeriodicSchedule(rule)
  }

  /// When a task is scheduled to be begun, if anything scheduled it.
  public func startAt(for taskId: String) throws -> Date? {
    try Self.mappingCoreErrors { try core.metadata(taskId: taskId) }?.startAtMs.map(Date.init(coreMilliseconds:))
  }
}
