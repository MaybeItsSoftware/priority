import Foundation
import TaktCore
import TaktRustCore

/// Everything the day and the focus ladder are drawn from, gathered in one go.
///
/// It is the most expensive read the desktop makes — every task, every
/// metadata row, the week's work — and it is also the one nothing has to wait
/// for: the outline a keystroke changed is on screen before the day needs to
/// agree with it. So it is a plain value computed from the store alone, which
/// lets the view model build it off the main thread and apply it when ready.
public struct WorkspaceNextUpSnapshot: Sendable {
  public let loggedSeconds: [String: Int]
  public let planning: [String: TaskPlanning]
  public let conditions: [TaskCondition]
  public let todayPlan: [DayPlanEntry]
  public let workProgress: WorkProgress
  public let ranking: FocusRanking
  /// The rows behind the day: every planned task, and the head of the ladder
  /// the day falls back to when nothing was planned. Read here so that drawing
  /// the day never has to go back to the database for them.
  public let dayTasks: [String: WorkspaceTask]
  /// Whether the ladder carries hand-placed positions, which the focus screen
  /// offers to clear.
  public let hasManualFocusOrder: Bool

  /// How many ranked tasks the day shows when nothing was planned for it.
  public static let fallbackDayLength = 8
}

extension WorkspaceStore {
  /// Safe to call from any thread: it only reads.
  ///
  /// The candidates are read, the day planned and the ladder ranked in one
  /// call to the Rust core (`next_up::next_up`), so the candidates never cross
  /// on their own. The day is gathered from every candidate rather than from
  /// the ranked ones: a task due today that a condition rules out is still
  /// part of today. With a `ladderLimit` the ladder holds only its first so
  /// many entries plus every task in the day further down, which is what the
  /// Mac draws and looks up; without one it is the whole ladder.
  public func nextUpSnapshot(
    workspaceId: String?, context: TaktCore.FocusContext, runningID: String?, now: Date = .now,
    ladderLimit: Int? = nil, calendar: Calendar = .current
  ) throws -> WorkspaceNextUpSnapshot {
    let loggedSeconds = try loggedWorkTotals()
    let planning = try taskPlanningValues()
    let conditions = try workspaceId.map { try self.conditions(in: $0) } ?? []
    let read = try Self.mappingCoreErrors {
      try core.nextUp(
        nowMs: now.coreMilliseconds, zone: calendar.timeZone.identifier, context: context.core,
        runningId: runningID, ladderLimit: ladderLimit.map { UInt32(max(0, $0)) })
    }
    let plan = read.dayPlan.map(DayPlanEntry.init)
    let ranking = FocusRanking(
      ranked: read.ranked, blocked: read.blocked, nextEvaluationAtMs: read.nextEvaluationAtMs)
    let progress = try workProgress(now: now, calendar: calendar)
    let dayIDs = plan.map(\.id) + ranking.ranked.prefix(WorkspaceNextUpSnapshot.fallbackDayLength).map(\.candidate.id)
    return WorkspaceNextUpSnapshot(
      loggedSeconds: loggedSeconds, planning: planning, conditions: conditions,
      todayPlan: plan, workProgress: progress, ranking: ranking,
      dayTasks: try tasks(ids: dayIDs), hasManualFocusOrder: try hasManualFocusOrder())
  }
}
