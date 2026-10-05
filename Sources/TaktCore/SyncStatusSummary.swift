import Foundation

/// How healthy the last thing the app tried to do was.
public enum SyncStatusSeverity: Sendable, Equatable {
  case ok
  case warning
  case problem
}

public struct SyncStatusSummary: Sendable, Equatable {
  public let text: String
  public let severity: SyncStatusSeverity

  public init(text: String, severity: SyncStatusSeverity) {
    self.text = text
    self.severity = severity
  }
}

/// The one-line "is this current?" readout, and the phrasing the diagnostics
/// pane reuses.
///
/// Ordered by what the user can act on rather than by severity: an error names
/// the thing that failed, and being offline explains an error you would
/// otherwise go looking for a cause for, so both outrank a stale timestamp.
public enum SyncStatusFormatter {

  public static func summary(
    isLoading: Bool,
    isNetworkReachable: Bool,
    canSyncRemotely: Bool,
    hasPendingOfflineWork: Bool,
    errorMessage: String?,
    lastSuccessfulSyncAt: Date?,
    now: Date = Date()
  ) -> SyncStatusSummary {
    if isLoading {
      return SyncStatusSummary(text: "Syncing…", severity: .ok)
    }
    if let errorMessage, !errorMessage.isEmpty {
      return SyncStatusSummary(text: errorMessage, severity: .problem)
    }
    if !isNetworkReachable {
      return SyncStatusSummary(
        text: hasPendingOfflineWork ? "Offline · changes queued" : "Offline",
        severity: .warning
      )
    }
    if !canSyncRemotely {
      // Not a fault. Working offline is a supported mode, and calling it a
      // problem would put a warning colour on the screen of everyone who never
      // connected Checkvist at all.
      return SyncStatusSummary(text: "Offline workspace", severity: .ok)
    }
    if hasPendingOfflineWork {
      return SyncStatusSummary(text: "Changes waiting to upload", severity: .warning)
    }
    guard let lastSuccessfulSyncAt else {
      return SyncStatusSummary(text: "Not synced yet", severity: .warning)
    }
    return SyncStatusSummary(
      text: "Synced \(relativeDescription(from: lastSuccessfulSyncAt, to: now))",
      severity: .ok
    )
  }

  /// Deliberately coarse. This sits in a 24pt strip and is read at a glance;
  /// "3m ago" answers the question and "3 minutes, 12 seconds ago" does not
  /// answer it any better while redrawing every second.
  public static func relativeDescription(from date: Date, to now: Date) -> String {
    let seconds = Int(now.timeIntervalSince(date).rounded())
    if seconds < 0 { return "just now" }
    if seconds < 45 { return "just now" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(max(1, minutes))m ago" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h ago" }
    return "\(hours / 24)d ago"
  }
}
