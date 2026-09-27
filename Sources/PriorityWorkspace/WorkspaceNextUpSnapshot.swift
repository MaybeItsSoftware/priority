import Foundation
import PriorityCore

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
  /// Safe to call from any thread: it only reads, and the pool serves reads
  /// concurrently with the writer.
  public func nextUpSnapshot(
    workspaceId: String?, context: FocusContext, runningID: String?, now: Date = .now
  ) throws -> WorkspaceNextUpSnapshot {
    let loggedSeconds = try loggedWorkTotals()
    let planning = try taskPlanningValues()
    let conditions = try workspaceId.map { try self.conditions(in: $0) } ?? []
    let candidates = try nextUpCandidates(now: now)
    // The day is gathered from every candidate rather than from the ranked
    // ones: a task due today that a condition currently rules out is still
    // part of today, and leaving it out would be the panel quietly deciding
    // the day was shorter than it is.
    let plan = DayPlanSelector.plan(candidates: candidates, runningID: runningID, now: now)
    let progress = try workProgress(now: now)
    let ranking = NextUpSelector.evaluate(candidates, now: now, context: context)
    let dayIDs = plan.map(\.id) + ranking.ranked.prefix(WorkspaceNextUpSnapshot.fallbackDayLength).map(\.candidate.id)
    return WorkspaceNextUpSnapshot(
      loggedSeconds: loggedSeconds, planning: planning, conditions: conditions,
      todayPlan: plan, workProgress: progress, ranking: ranking,
      dayTasks: try tasks(ids: dayIDs), hasManualFocusOrder: try hasManualFocusOrder())
  }
}
