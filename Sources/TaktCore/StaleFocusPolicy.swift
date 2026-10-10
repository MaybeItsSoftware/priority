import Foundation
import TaktRustCore

/// What becomes of a block that was paused and then left.
public enum StaleFocusResolution: String, Sendable, Equatable, CaseIterable {
  /// Still today's block. It stays paused, and resuming it stays a decision.
  case keep
  /// Close it out, crediting the seconds it actually accumulated to the day it
  /// was worked on rather than to the day you came back.
  case close
  /// End it without crediting anything. There is nothing to credit.
  case discard

  /// The Rust core's `StaleFocusOutcome`.
  public init(core outcome: StaleFocusOutcome) {
    switch outcome {
    case .keep: self = .keep
    case .close: self = .close
    case .discard: self = .discard
    }
  }
}

/// Whether a paused focus session is still live when the app comes back.
///
/// `applicationWillTerminate` pauses the running block so the clock does not
/// accrue while the app is dead. That is right, but it means every quit leaves
/// a paused session behind, and nothing used to clear it: reopening the app
/// days later restored a block from a day that was long over.
///
/// The rule is the logical day. A block belongs to the day it was worked on,
/// so one paused on an earlier day is finished rather than resumed. Within the
/// same logical day it is left alone, because stepping out for lunch is not
/// abandoning the work. A paused session with no task on it is discarded at
/// once: it has nothing to credit and nothing to resume.
///
/// The Rust core's `progress::stale_focus_outcome`; the store's
/// `resolveStaleFocusSession` runs it in the core against the session row.
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
    StaleFocusResolution(
      core: staleFocusOutcome(
        pausedAtMs: pausedAt?.rankingMilliseconds, accumulatedSeconds: Int64(accumulatedSeconds),
        hasActiveTask: hasActiveTask, nowMs: now.rankingMilliseconds,
        rolloverHour: UInt8(clamping: boundary.rolloverHour), zone: boundary.calendar.timeZone.identifier))
  }
}
