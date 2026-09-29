import Foundation

/// How much of the day's plan is left and, if you worked straight through it,
/// when you would be done.
///
/// Blitzit's point is that a list of tasks with estimates already knows the
/// answer to "when do I get to stop", so the day should say it rather than
/// leave the sum to you. It is deliberately naive: no breaks, no calendar, no
/// working hours. A finish time you can check in your head is worth more than
/// a clever one you have to trust.
public struct DayForecast: Equatable, Sendable {
  /// One task on the day, as far as the forecast cares about it.
  public struct Entry: Equatable, Sendable {
    /// What the task was meant to cost, or nil when nobody said.
    public var estimateSeconds: Int?
    /// What it has cost so far, *including* the running block's elapsed time
    /// when this is the task being worked on — the stored totals only gain a
    /// block when it ends, so without it the finish time would stand still
    /// for the whole of the block you are sitting in.
    public var loggedSeconds: Int

    public init(estimateSeconds: Int?, loggedSeconds: Int) {
      self.estimateSeconds = estimateSeconds
      self.loggedSeconds = loggedSeconds
    }
  }

  /// The sum of every estimate on the day.
  public let estimatedSeconds: Int
  /// Time logged against the day's tasks, estimated or not.
  public let loggedSeconds: Int
  /// What the estimated tasks still owe. A task already past its estimate
  /// owes nothing rather than a negative amount: an overrun on one task does
  /// not buy time back on the others.
  public let remainingSeconds: Int
  /// Tasks that say nothing about their cost, so the forecast cannot count
  /// them — worth telling the reader, since each one makes it optimistic.
  public let unestimatedCount: Int
  /// `now` plus what is left, or nil when nothing estimated is left to do.
  public let finishAt: Date?

  public init(entries: [Entry], now: Date) {
    var estimated = 0
    var logged = 0
    var remaining = 0
    var unestimated = 0
    for entry in entries {
      let spent = max(0, entry.loggedSeconds)
      logged += spent
      guard let estimate = entry.estimateSeconds, estimate > 0 else {
        unestimated += 1
        continue
      }
      estimated += estimate
      remaining += max(0, estimate - spent)
    }
    estimatedSeconds = estimated
    loggedSeconds = logged
    remainingSeconds = remaining
    unestimatedCount = unestimated
    finishAt = remaining > 0 ? now.addingTimeInterval(TimeInterval(remaining)) : nil
  }
}
