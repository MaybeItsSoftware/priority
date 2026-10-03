import Foundation
import PriorityCore

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

  /// How the row looks at each phase — the same data the Mac's presets
  /// carry, so a Strike on the phone is the Mac's Strike.
  var treatment: CelebrationRowTreatment {
    switch self {
    case .strike: .strike
    case .spark: .spark
    case .fold: .fold
    case .none: .none
    }
  }

  /// The schedule the row runs on, with the Mac presets' beats
  /// (`StrikeCelebrationPlugin`, `SparkCelebrationPlugin`,
  /// `FoldCelebrationPlugin`), fitted to the shared inline budget. Reduce
  /// Motion collapses the durations rather than dropping the effect.
  func script(reduceMotion: Bool) -> CelebrationScript {
    let steps: [CelebrationScript.Step]
    switch self {
    case .strike:
      // A wind-up, the rule drawn, then a beat for the struck state to land.
      steps = [
        .init(phase: .anticipating, duration: 0.025),
        .init(phase: .celebrating, duration: 0.115),
        .init(phase: .celebrating, duration: 0.055),
      ]
    case .spark:
      steps = [.init(phase: .anticipating, duration: 0.03), .init(phase: .celebrating, duration: 0.15)]
    case .fold:
      // A beat at full height first, so the collapse reads as a fold rather
      // than a jump cut.
      steps = [.init(phase: .anticipating, duration: 0.04), .init(phase: .celebrating, duration: 0.13)]
    case .none:
      return .empty
    }
    return CelebrationScript.fitting(steps, budget: CompletionMilestonePolicy.inlineBudget, reduceMotion: reduceMotion)
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
