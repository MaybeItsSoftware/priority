import AppIntents
import Foundation

/// Opens Priority on its quick-add sheet. Run by the Control Center control
/// and offered to Shortcuts.
///
/// Compiled into the app and the widget extension both, as a control's intent
/// must be; the system performs it in the app, because it opens the app. The
/// request is also left in the shared defaults, so a cold launch — where the
/// app's handler is not yet installed — still opens the sheet once it is.
struct OpenQuickAddIntent: AppIntent {
  static let title: LocalizedStringResource = "Quick add"
  static let description = IntentDescription("Opens Priority ready to capture a task.")
  static let openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    QuickAddRequest.post()
    return .result()
  }
}

/// The hand-off between the intent and the app's UI.
@MainActor
enum QuickAddRequest {
  static let defaultsKey = "pendingQuickAdd"
  /// Set by the app once its workspace is open.
  static var handler: (() -> Void)?

  static func post() {
    if let handler {
      handler()
    } else {
      AppGroup.defaults.set(true, forKey: defaultsKey)
    }
  }

  /// Whether a request is waiting, clearing it.
  static func takePending() -> Bool {
    guard AppGroup.defaults.bool(forKey: defaultsKey) else { return false }
    AppGroup.defaults.removeObject(forKey: defaultsKey)
    return true
  }
}
