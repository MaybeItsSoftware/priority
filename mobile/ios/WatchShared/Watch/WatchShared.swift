import Foundation
import SwiftUI

// What the watch app and its complications share: where the last snapshot
// is kept, the palette and how numbers are written. Not compiled into the
// iPhone, which has its own theme.

/// The container the watch app and its complications share. The watch app
/// writes the last snapshot the phone sent; the complications only read it.
enum WatchStorage {
  static let appGroup = "group.uk.co.maybeitssoftware.takt"
  /// The complication's WidgetKit kind.
  static let widgetKind = "TaktWatchNow"

  static var containerURL: URL {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  }

  static var snapshotURL: URL {
    containerURL.appending(path: "Takt/watch-snapshot.json", directoryHint: .notDirectory)
  }

  static func load(from url: URL = snapshotURL) -> WatchSnapshot? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? WatchSnapshot.decode(data)
  }

  static func save(_ snapshot: WatchSnapshot, to url: URL = snapshotURL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try snapshot.encoded().write(to: url, options: .atomic)
  }
}

/// Takt's palette on the watch: the dark grape surfaces, azure for what you
/// can act on, and the status hues for what happened. The watch is always
/// dark, so there is one set rather than a pair.
enum WatchPalette {
  static let page = Color(hex: 0x1C1A23)
  static let raised = Color(hex: 0x25232F)
  static let subtle = Color(hex: 0x2D2B38)
  static let border = Color(hex: 0x34313F)
  static let text = Color(hex: 0xF5F4F7)
  static let muted = Color(hex: 0xB6B3BF)
  static let dim = Color(hex: 0x6E6B7C)
  static let azure = Color(hex: 0x007FFF)
  static let emerald = Color(hex: 0x4CC38E)
  static let raspberry = Color(hex: 0xD62246)
  static let amber = Color(hex: 0xFFBF00)
}

extension Color {
  init(hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
  }
}

/// How the watch writes numbers, matching the iPhone's `Format`.
enum WatchFormat {
  /// `25m`, `1h`, `1h 30m`.
  static func duration(_ seconds: Int) -> String {
    let minutes = max(0, Int((Double(seconds) / 60).rounded()))
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    let rest = minutes % 60
    return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
  }

  /// `12:04` or `1:02:04`.
  static func clock(_ seconds: Int) -> String {
    let seconds = max(0, seconds)
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    let rest = seconds % 60
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, rest) }
    return String(format: "%d:%02d", minutes, rest)
  }

  /// A row's small line: its reason or list, then its estimate.
  static func detail(_ task: WatchSnapshot.Task) -> String? {
    let parts = [task.detail, task.estimateSeconds.map(duration)].compactMap { $0 }.filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// How old the snapshot is, when that is worth saying: "Updated 12m ago".
  static func age(of snapshot: WatchSnapshot, now: Date) -> String? {
    let seconds = now.timeIntervalSince(snapshot.generatedAt)
    guard snapshot.generatedAt != .distantPast, seconds >= 120 else { return nil }
    if seconds < 3_600 { return "Updated \(Int(seconds / 60))m ago" }
    if seconds < 86_400 { return "Updated \(Int(seconds / 3_600))h ago" }
    return "Updated " + snapshot.generatedAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
  }
}
