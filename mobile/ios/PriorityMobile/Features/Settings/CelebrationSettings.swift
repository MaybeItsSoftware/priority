import Foundation

/// How finishing something is marked. The Mac's celebration plugins, by the
/// same names (`Priority/Plugins/Native/Celebration`): Strike rules the row
/// through, Spark throws a few sparks, Fold folds the row away, None is quiet.
enum CelebrationStyle: String, CaseIterable, Identifiable {
  case strike, spark, fold, none

  static let storageKey = "celebrationStyle"
  static let `default` = CelebrationStyle.strike

  var id: String { rawValue }

  var title: String {
    switch self {
    case .strike: "Strike"
    case .spark: "Spark"
    case .fold: "Fold"
    case .none: "None"
    }
  }

  var detail: String {
    switch self {
    case .strike: "A rule drawn through the finished row."
    case .spark: "A brief spark where the row was."
    case .fold: "The row folds away."
    case .none: "Nothing but the tick."
    }
  }

  /// The stored choice, falling back to the default for anything unknown.
  static func stored(in defaults: UserDefaults = .standard) -> CelebrationStyle {
    defaults.string(forKey: storageKey).flatMap(CelebrationStyle.init(rawValue:)) ?? .default
  }
}

/// Whether completing a task plays a haptic.
enum CompletionHaptics {
  static let storageKey = "completionHaptics"

  static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: storageKey) as? Bool ?? true
  }
}
