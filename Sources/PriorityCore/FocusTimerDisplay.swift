import Foundation

/// How a running focus block reads in the menu bar.
///
/// It counts **down** to the estimate, then **up** past it with a leading `+`.
///
/// Down first, because a visible finish line is what makes the estimate mean
/// anything: the closer the end gets the harder it pulls, which a number
/// climbing from zero never does — an open-ended count is just a record of how
/// long you have been at it. But a countdown that stops at 00:00, or goes
/// negative, either lies about the sitting or turns overrun into a failure
/// state. Flipping to `+2:14` keeps the clock honest, keeps the overrun
/// legible, and makes the estimate something you get feedback on rather than
/// something you quietly blow past.
public enum FocusTimerDisplay {
  public struct Reading: Sendable, Equatable {
    public let text: String
    /// True once the estimate has been passed. Callers use it to tint the
    /// menu-bar title rather than to change what the clock says.
    public let isOverrun: Bool

    public init(text: String, isOverrun: Bool) {
      self.text = text
      self.isOverrun = isOverrun
    }
  }

  public static func reading(elapsed: TimeInterval, planned: TimeInterval) -> Reading {
    let elapsedSeconds = Int(max(0, elapsed.rounded(.down)))
    let plannedSeconds = Int(max(0, planned.rounded(.down)))
    let remaining = plannedSeconds - elapsedSeconds
    if remaining >= 0 {
      return Reading(text: clock(remaining), isOverrun: false)
    }
    return Reading(text: "+" + clock(-remaining), isOverrun: true)
  }

  /// `m:ss` under an hour, `h:mm:ss` beyond it — the menu bar is too narrow to
  /// spend two characters on a leading zero that is almost always there.
  private static func clock(_ seconds: Int) -> String {
    let hours = seconds / 3_600
    let minutes = (seconds % 3_600) / 60
    let secs = seconds % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
  }
}
