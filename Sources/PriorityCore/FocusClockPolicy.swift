import Foundation

/// Live active work follows elapsed uptime, even if the wall clock is adjusted.
/// Persisted checkpoints remain the recovery boundary across process restarts.
public enum FocusClockPolicy {
  public static func adjustedElapsed(previousElapsed: Int, wallDelta: TimeInterval,
                                     uptimeDelta: TimeInterval) -> Int? {
    guard wallDelta.isFinite, uptimeDelta.isFinite, uptimeDelta >= 0,
      abs(wallDelta - uptimeDelta) > 3 else { return nil }
    let addition = uptimeDelta.rounded(.down)
    guard addition < Double(Int.max - max(0, previousElapsed)) else { return max(0, previousElapsed) }
    return max(0, previousElapsed) + Int(addition)
  }
}
