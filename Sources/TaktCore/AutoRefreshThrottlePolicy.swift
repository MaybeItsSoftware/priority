import Foundation

public enum AutoRefreshThrottlePolicy {
  public static func shouldRefresh(
    now: Date,
    lastRefreshAt: Date,
    minimumInterval: TimeInterval = 8
  ) -> Bool {
    now.timeIntervalSince(lastRefreshAt) > minimumInterval
  }
}
