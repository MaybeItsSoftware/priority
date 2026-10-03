import Foundation

/// A flat snapshot of everything the report prints.
///
/// A plain value rather than a reference to the live managers, so the formatter
/// stays pure and testable and cannot accidentally read a secret it was not
/// handed. Whoever builds the snapshot decides what crosses this line.
public struct DiagnosticsSnapshot: Sendable {

  public struct HealthItem: Sendable {
    public let title: String
    public let isHealthy: Bool
    public let detail: String

    public init(title: String, isHealthy: Bool, detail: String) {
      self.title = title
      self.isHealthy = isHealthy
      self.detail = detail
    }
  }

  public struct LogItem: Sendable {
    public let date: Date
    public let category: String
    public let message: String
    public let isFailure: Bool

    public init(date: Date, category: String, message: String, isFailure: Bool) {
      self.date = date
      self.category = category
      self.message = message
      self.isFailure = isFailure
    }
  }

  public let appVersion: String
  public let buildNumber: String
  public let generatedAt: Date
  public let connectionDescription: String
  public let listName: String
  public let listID: String
  public let isNetworkReachable: Bool
  public let syncStatus: String
  public let lastSuccessfulSyncAt: Date?
  public let openTaskCount: Int
  public let pendingOfflineWorkCount: Int
  public let health: [HealthItem]
  public let recentProblems: [LogItem]
  public let paths: [(label: String, path: String)]

  public init(
    appVersion: String,
    buildNumber: String,
    generatedAt: Date,
    connectionDescription: String,
    listName: String,
    listID: String,
    isNetworkReachable: Bool,
    syncStatus: String,
    lastSuccessfulSyncAt: Date?,
    openTaskCount: Int,
    pendingOfflineWorkCount: Int,
    health: [HealthItem],
    recentProblems: [LogItem],
    paths: [(label: String, path: String)]
  ) {
    self.appVersion = appVersion
    self.buildNumber = buildNumber
    self.generatedAt = generatedAt
    self.connectionDescription = connectionDescription
    self.listName = listName
    self.listID = listID
    self.isNetworkReachable = isNetworkReachable
    self.syncStatus = syncStatus
    self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
    self.openTaskCount = openTaskCount
    self.pendingOfflineWorkCount = pendingOfflineWorkCount
    self.health = health
    self.recentProblems = recentProblems
    self.paths = paths
  }
}

/// Renders a diagnostics snapshot as text a user can paste into an issue.
///
/// Plain text on purpose: it survives being pasted anywhere, and a support
/// report nobody can read is not one.
public enum DiagnosticsReport {

  /// Anything shaped like a credential, whatever it is labelled.
  ///
  /// Belt and braces over the snapshot never being handed a secret in the first
  /// place. A report is something the user is invited to post in public, so the
  /// cost of one leak is far higher than the cost of over-redacting a path that
  /// happened to contain a long hex string. The MCP client configuration no
  /// longer carries credentials at all, but a report sweeps up whatever the
  /// user pasted into it, so the patterns stay.
  private static let secretPatterns: [String] = [
    // key=value / "key": "value" for anything named like a credential. The
    // optional quote before the separator is what makes this work on JSON,
    // which is the shape the MCP client configuration is in.
    #"(?i)(api[_-]?key|remote[_-]?key|token|secret|password|authorization|bearer)"#
      + #""?\s*[:=]\s*"?([^\s",}]+)"?"#,
    // Bare long hex/base64-ish runs, which is what Checkvist remote keys look like
    #"\b[A-Za-z0-9+/_-]{24,}\b"#,
  ]

  public static func redacting(_ text: String) -> String {
    var result = text
    for pattern in secretPatterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(result.startIndex..., in: result)
      // Keep the label, drop the value: "api_key: <redacted>" still tells the
      // reader which credential was involved, which is usually the useful half.
      let template = pattern.contains("[:=]") ? "$1: <redacted>" : "<redacted>"
      result = regex.stringByReplacingMatches(
        in: result, range: range, withTemplate: template)
    }
    return result
  }

  public static func text(from snapshot: DiagnosticsSnapshot) -> String {
    var lines: [String] = []

    lines.append("Takt diagnostics")
    lines.append("====================")
    lines.append("Generated: \(timestamp(snapshot.generatedAt))")
    lines.append("Version:   \(snapshot.appVersion) (\(snapshot.buildNumber))")
    lines.append("")

    lines.append("Status")
    lines.append("------")
    lines.append("Connection:     \(snapshot.connectionDescription)")
    lines.append("List:           \(listDescription(snapshot))")
    lines.append("Network:        \(snapshot.isNetworkReachable ? "reachable" : "unreachable")")
    lines.append("Sync:           \(snapshot.syncStatus)")
    lines.append(
      "Last sync:      "
        + (snapshot.lastSuccessfulSyncAt.map(timestamp) ?? "never this session"))
    lines.append("Open tasks:     \(snapshot.openTaskCount)")
    lines.append("Queued offline: \(snapshot.pendingOfflineWorkCount)")
    lines.append("")

    if !snapshot.health.isEmpty {
      lines.append("Health")
      lines.append("------")
      for item in snapshot.health {
        lines.append("[\(item.isHealthy ? "ok" : "!!")] \(item.title)")
        if !item.detail.isEmpty {
          for detailLine in item.detail.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append("     \(detailLine)")
          }
        }
      }
      lines.append("")
    }

    lines.append("Recent problems")
    lines.append("---------------")
    if snapshot.recentProblems.isEmpty {
      lines.append("(none recorded this session)")
    } else {
      for item in snapshot.recentProblems {
        let marker = item.isFailure ? "!!" : "  "
        lines.append("\(marker) \(timestamp(item.date))  [\(item.category)] \(item.message)")
      }
    }
    lines.append("")

    if !snapshot.paths.isEmpty {
      lines.append("Data")
      lines.append("----")
      let width = snapshot.paths.map(\.label.count).max() ?? 0
      for entry in snapshot.paths {
        let padding = String(repeating: " ", count: max(0, width - entry.label.count))
        lines.append("\(entry.label)\(padding)  \(entry.path)")
      }
      lines.append("")
    }

    return redacting(lines.joined(separator: "\n"))
  }

  private static func listDescription(_ snapshot: DiagnosticsSnapshot) -> String {
    if snapshot.listID.isEmpty { return "offline workspace" }
    if snapshot.listName.isEmpty { return "id \(snapshot.listID) (name unknown)" }
    return "\(snapshot.listName) (id \(snapshot.listID))"
  }

  /// ISO-8601 in the local time zone: sortable and unambiguous, but still the
  /// clock the person reading it was looking at when the thing went wrong.
  private static func timestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: date)
  }
}
