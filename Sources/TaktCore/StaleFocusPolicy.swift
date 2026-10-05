import Foundation

/// What becomes of a block that was paused and then left.
public enum StaleFocusResolution: String, Sendable, Equatable, CaseIterable {
  /// Still today's block. It stays paused, and resuming it stays a decision.
  case keep
  /// Close it out, crediting the seconds it actually accumulated to the day it
  /// was worked on rather than to the day you came back.
  case close
  /// End it without crediting anything. There is nothing to credit.
  case discard
}

/// Whether a paused focus session is still live when the app comes back.
///
/// `applicationWillTerminate` pauses the running block so the clock does not
/// accrue while the app is dead. That is right, but it means every quit leaves
/// a paused session behind, and nothing used to clear it: reopening the app
/// days later restored a block from a day that was long over, sat it on the
/// focus screen, and put it in the menu bar as the thing you were supposedly
/// doing.
///
/// The rule is the logical day. A block belongs to the day it was worked on,
/// so one paused on an earlier day is finished rather than resumed — you are
/// not returning to Tuesday's sitting on Thursday. Within the same logical day
/// it is left alone, because stepping out for lunch is not abandoning the work.
public enum StaleFocusPolicy {
  /// Under a minute is not a sitting. Blocks that short are ended rather than
  /// written into the history, where they would read as work done.
  public static let minimumCreditedSeconds = 60

  public static func resolution(
    pausedAt: Date?,
    accumulatedSeconds: Int,
    hasActiveTask: Bool = true,
    now: Date,
    boundary: DayBoundary = DayBoundary()
  ) -> StaleFocusResolution {
    // Running, not paused: nothing to decide. Recovery pauses an interrupted
    // session before this is asked, so in practice a nil means it is live.
    guard let pausedAt else { return .keep }
    guard boundary.logicalDay(for: pausedAt) < boundary.logicalDay(for: now) else { return .keep }
    // A session whose queue ran dry has no block to credit, whatever it
    // accumulated against the task it has already finished with.
    guard hasActiveTask else { return .discard }
    return accumulatedSeconds >= minimumCreditedSeconds ? .close : .discard
  }
}
