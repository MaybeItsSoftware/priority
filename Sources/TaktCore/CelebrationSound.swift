import Foundation

/// The audible half of a completion, as data.
///
/// Sound is here rather than hardcoded next to the haptic because of who
/// actually receives the haptic. `NSHapticFeedbackManager` drives the Force
/// Touch trackpad and nothing else: it is silent on a Magic Keyboard and mouse,
/// silent on an external keyboard, and silent even on a laptop whose trackpad
/// nobody is touching at the moment the key lands. For a keyboard-first menu
/// bar app that is most completions, which left the "tactile" half of the
/// feedback reaching almost no one.
///
/// A short tick is the substitute every other task app reaches for, and it is
/// per-preset rather than global because the right sound for `Fold` is not the
/// right sound for `Spark`. It stays *off* by default — an app that starts
/// making noise without being asked is worse than one that is quiet — and the
/// user turns it on once, in Settings → Theme, for whichever preset they run.
///
/// Named rather than bundled: these are the system sounds in
/// `/System/Library/Sounds`, so the app ships no audio, and a name that no
/// longer resolves degrades to silence rather than to a crash.
public struct CelebrationSound: Equatable, Sendable {
  /// A name `NSSound(named:)` resolves — i.e. one of the system sounds.
  public let systemName: String
  /// 0...1. Deliberately quiet by default: this is punctuation, not an alert,
  /// and it fires on every completion of a working session.
  public let volume: Float

  public init(systemName: String, volume: Float = 0.35) {
    self.systemName = systemName
    self.volume = max(0, min(1, volume))
  }

  /// Short and dry. The default tick — closest thing the system has to a key
  /// travelling.
  public static let tick = CelebrationSound(systemName: "Pop", volume: 0.3)
  /// Softer and lower, for a row that is folding away rather than being marked.
  public static let soft = CelebrationSound(systemName: "Tink", volume: 0.25)
  /// Brighter, for the preset that throws particles.
  public static let bright = CelebrationSound(systemName: "Glass", volume: 0.25)
  /// Reserved for milestones — the one occasion that has earned being louder
  /// than punctuation.
  public static let milestone = CelebrationSound(systemName: "Hero", volume: 0.35)
}
