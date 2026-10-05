import Foundation

/// The container the app, its widgets and its intents share.
///
/// The workspace database lives here rather than in the app's own Application
/// Support, so a widget timeline or an App Intent can read the same file the
/// app writes. Everything outside the app reads it; only the app (and the
/// intents it runs) writes it.
enum AppGroup {
  static let identifier = "group.uk.co.maybeitssoftware.takt"

  /// Set by the UI tests so every run starts from an empty workspace.
  static var isUITesting: Bool {
    ProcessInfo.processInfo.arguments.contains("-uiTesting")
  }

  static var containerURL: URL {
    if isUITesting {
      return FileManager.default.temporaryDirectory.appending(path: "TaktUITests", directoryHint: .isDirectory)
    }
    return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  }

  static var databaseURL: URL {
    containerURL.appending(path: "Priority/priority.sqlite", directoryHint: .notDirectory)
  }

  /// Unsaved inspector edits. Local editing state, never a task mutation.
  static var draftsURL: URL {
    containerURL.appending(path: "Priority/task-drafts.json", directoryHint: .notDirectory)
  }

  /// What the widgets draw, written by the app after each change.
  static var widgetSnapshotURL: URL {
    containerURL.appending(path: "Priority/widget-snapshot.json", directoryHint: .notDirectory)
  }

  static var defaults: UserDefaults {
    UserDefaults(suiteName: identifier) ?? .standard
  }
}
