import Foundation

/// Where a row is in its completion sequence.
///
/// Three states rather than the boolean this replaces, because a completion
/// that starts at full value reads as a flicker. `anticipating` is the couple
/// of frames of counter-motion before the pop — the row dips slightly *away*
/// from where it is about to go — which is what makes a 180ms effect read as
/// deliberate rather than as a glitch. It is motion only: no tint, no
/// strikethrough, no collapse happens until `celebrating`.
public enum CelebrationPhase: String, Equatable, Sendable, CaseIterable {
  /// Not completing. The row's ordinary appearance.
  case idle
  /// Winding up. Counter-motion only.
  case anticipating
  /// The effect proper — tint, strike, collapse, pop.
  case celebrating
}

/// The schedule a celebration runs on, as data.
///
/// Presets used to express their timing as a hand-written sequence of
/// `Task.sleep` calls interleaved with `withAnimation`, which had two
/// consequences worth undoing. The first is that nothing could check the
/// timing: `Native/Celebration/` is excluded from the `TaktPlugins` target
/// because celebrations are SwiftUI, so a preset's budget arithmetic was
/// unreachable from any test. The second is that
/// `CompletionMilestonePolicy.inlineBudget` was enforced *per sleep* rather
/// than over the sequence — three clamped 220ms steps satisfied every clamp
/// individually and still took 660ms.
///
/// Splitting the schedule from its rendering fixes both. A preset returns one
/// of these; `CompletionCelebrationPlugin`'s default `runInline` plays it; and
/// `fitting(_:budget:reduceMotion:)` — pure, here, tested — is the single place
/// the budget is applied, to the total rather than to each step.
public struct CelebrationScript: Equatable, Sendable {

  /// One beat: a phase to be in, and how long to stay in it.
  ///
  /// Repeating a phase is how a script holds — a second `celebrating` step
  /// changes nothing on screen and simply waits, which is exactly what "let the
  /// struck state register before the row goes" means.
  public struct Step: Equatable, Sendable {
    public let phase: CelebrationPhase
    public let duration: TimeInterval

    public init(phase: CelebrationPhase, duration: TimeInterval) {
      self.phase = phase
      self.duration = duration
    }
  }

  public let steps: [Step]

  public init(steps: [Step]) {
    self.steps = steps
  }

  /// Nothing at all. What `None` returns, and what any preset returns for an
  /// occasion it does not want to mark.
  public static let empty = CelebrationScript(steps: [])

  /// How long the whole sequence takes. This — not any individual step — is
  /// what the budget bounds.
  public var total: TimeInterval {
    steps.reduce(0) { $0 + $1.duration }
  }

  /// Applies the reduced-motion scale, then shrinks the sequence to fit
  /// `budget` if it still overruns.
  ///
  /// Proportional rather than truncating, deliberately. Clamping step by step —
  /// what `CompletionMilestonePolicy.clampedDuration` does, and all a preset
  /// could reach for before — preserves the overrun and distorts the sequence's
  /// shape: a script that wants 20/120/60 and is given half the room should
  /// still land in those proportions, not lose its last beat entirely.
  public static func fitting(
    _ requested: [Step],
    budget: TimeInterval,
    reduceMotion: Bool
  ) -> CelebrationScript {
    let motionScale = CompletionMilestonePolicy.durationScale(reduceMotion: reduceMotion)
    let scaled = requested.map {
      Step(phase: $0.phase, duration: max(0, $0.duration) * motionScale)
    }
    let total = scaled.reduce(0) { $0 + $1.duration }
    guard total > budget, total > 0 else {
      return CelebrationScript(steps: scaled)
    }
    let shrink = budget / total
    return CelebrationScript(
      steps: scaled.map { Step(phase: $0.phase, duration: $0.duration * shrink) }
    )
  }
}
