import Foundation

/// What the widgets draw, written by the app after each change and read by
/// the widget extension's timeline.
///
/// A plain file rather than a database read in the extension: a widget
/// timeline has a few milliseconds and a small memory budget, and the ranking
/// behind "next up" reads the whole workspace. The app ranks; the widget reads
/// the answer.
struct WidgetSnapshot: Codable, Equatable, Sendable {
  struct Item: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    /// Why it is in the day — "Planned", "Overdue" — or nil for a task the
    /// ranking offered because nothing was planned.
    let reason: String?
    let estimateSeconds: Int?
    let listName: String?
  }

  struct Running: Codable, Equatable, Sendable {
    let taskID: String
    let title: String
    /// When the clock would have started had it never paused, so a widget can
    /// draw a live timer from it.
    let timerStart: Date
    let isPaused: Bool
    let elapsedSeconds: Int
  }

  var generatedAt: Date
  /// The day, in order: what Today shows, or the head of the ranking when
  /// nothing was planned.
  var items: [Item]
  /// How many tasks today has a claim on — planned, overdue, due or starting.
  var todayCount: Int
  /// Estimated time still owed to today's tasks.
  var remainingSeconds: Int
  var completedToday: Int
  var loggedTodaySeconds: Int
  var running: Running?

  static let empty = WidgetSnapshot(
    generatedAt: .distantPast, items: [], todayCount: 0, remainingSeconds: 0, completedToday: 0,
    loggedTodaySeconds: 0, running: nil)

  /// The first thing in the day that is not already running.
  var nextUp: Item? { items.first { $0.id != running?.taskID } }

  /// Equal apart from when it was made: what decides whether to rewrite it.
  func hasSameContent(as other: WidgetSnapshot) -> Bool {
    var copy = other
    copy.generatedAt = generatedAt
    return copy == self
  }

  static func load(from url: URL = AppGroup.widgetSnapshotURL) -> WidgetSnapshot? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(WidgetSnapshot.self, from: data)
  }

  func write(to url: URL = AppGroup.widgetSnapshotURL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(self).write(to: url, options: .atomic)
  }

  static let sample = WidgetSnapshot(
    generatedAt: .now,
    items: [
      Item(id: "1", title: "Polish the outline rows", reason: "Due today", estimateSeconds: 2_700, listName: "Work"),
      Item(id: "2", title: "Take screenshots", reason: "Planned", estimateSeconds: 1_200, listName: "Work"),
      Item(id: "3", title: "Groceries", reason: "Planned", estimateSeconds: 2_400, listName: "Home"),
    ],
    todayCount: 3, remainingSeconds: 6_300, completedToday: 2, loggedTodaySeconds: 3_000, running: nil)
}
