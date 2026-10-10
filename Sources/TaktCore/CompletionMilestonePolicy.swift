import Foundation
import TaktRustCore

/// What was just completed, and which row it belongs to.
///
/// Tasks and dailies are keyed differently (`Int` vs `String`) because they are
/// genuinely different things stored in different files — a task id comes from
/// Checkvist, a daily id from `dailies.json`. Folding the identifier into the
/// case keeps the two from being mixed up by a caller holding the wrong one.
public enum CompletionKind: Equatable, Hashable, Sendable {
  case task(id: Int)
  case daily(id: String)
  /// A task in the local desktop workspace, which keys by UUID rather than by
  /// the `Int` Checkvist hands out. A separate case rather than a widened `id`
  /// so the two can never be compared and found equal by accident.
  case workspaceTask(id: String)

  public var isDaily: Bool {
    if case .daily = self { return true }
    return false
  }

  /// Whether this is a unit of work that can run out — as opposed to a daily,
  /// which resets. What "the list is now clear" is a statement about.
  public var isTask: Bool {
    switch self {
    case .task, .workspaceTask: return true
    case .daily: return false
    }
  }
}

/// How hard a completion should land.
///
/// Deliberately a closed set rather than a numeric "intensity": a celebration
/// plugin should be able to switch on the *occasion*, not guess what a 0.7
/// means.
public enum CompletionMilestone: Equatable, Sendable {
  /// The common case — the great majority of completions.
  case ordinary
  /// The last visible task went away, so the list is now empty.
  case listCleared
  /// A recurring intention was ticked (never fires for un-ticking).
  case dailyTicked
  /// The Nth completion of the logical day, N a multiple of `tallyInterval`.
  case dailyTally(count: Int)
  /// The first completion of a day that extends a run of consecutive days,
  /// `days` long including today.
  ///
  /// Worth more than the tally it outranks. Ten completions in a day is a
  /// number that says how busy the day was; a run of days says you kept showing
  /// up, which is the thing the app is actually for — and, unlike a tally, it
  /// is a number you can lose, which is what gives it its pull.
  case dailyStreak(days: Int)

  /// Whether this occasion earns a post-mutation flourish on top of the inline
  /// effect.
  ///
  /// Routine completions do not, so ordinary work stays as fast and as quiet as
  /// it is today — and `dailyTicked` is routine, whatever its name suggests.
  /// `milestone(for:…)` returns it for *every* tick of *every* daily, so a
  /// flourish here fires several times each morning. The Strike preset draws
  /// its flourish as a rule swept across the panel, which is deliberately the
  /// same gesture as the row's own strikethrough — so what that actually looked
  /// like was a second strikethrough appearing at a fixed point on the panel
  /// after each tick, unrelated to the row you had just ticked.
  ///
  /// A tick keeps its inline celebration: the rule through the row, the glyph
  /// pop, the tint. What it loses is the panel-wide echo of that same gesture.
  /// The occasions that still earn one all say something a tick does not — a
  /// streak, a tally, an emptied list.
  public var earnsFlourish: Bool {
    switch self {
    case .ordinary, .dailyTicked: return false
    case .dailyTally, .dailyStreak, .listCleared: return true
    }
  }

  /// How much room the flourish should take, `0...1`.
  ///
  /// Clearing your list is the rarest and most earned thing that happens in the
  /// app and it used to get a 1.5pt rule — visibly *less* than the row it
  /// followed. Presets scale their flourish by this rather than each inventing
  /// a hierarchy, so the ordering holds however they choose to draw it.
  public var flourishWeight: Double {
    switch self {
    case .ordinary: return 0
    case .dailyTicked: return 0.45
    case .dailyTally: return 0.7
    case .dailyStreak: return 0.85
    case .listCleared: return 1.0
    }
  }

  /// A short caption for the flourish, or `nil` where the motion says it.
  ///
  /// Only the two occasions carrying a *number* get words — a streak and a
  /// tally mean nothing without one. Clearing the list needs no caption: an
  /// empty list is its own announcement.
  public var caption: String? {
    switch self {
    case .dailyStreak(let days): return "\(days) day streak"
    case .dailyTally(let count): return "\(count) today"
    case .ordinary, .dailyTicked, .listCleared: return nil
    }
  }
}

public struct CompletionEvent: Equatable, Sendable {
  public let kind: CompletionKind
  public let milestone: CompletionMilestone
  /// Which completion of the logical day this one is, counting from 1.
  public let ordinal: Int

  public init(
    kind: CompletionKind,
    milestone: CompletionMilestone,
    ordinal: Int
  ) {
  self.kind = kind
  self.milestone = milestone
  self.ordinal = ordinal
  }
}

/// Decides which occasion a completion is, and how long the effect may run.
///
/// Pure and headless so it can be tested without the app: the interesting part
/// is the precedence between overlapping milestones (clearing your list on your
/// tenth completion is one celebration, not two) and the duration budget, which
/// exists for a reason that is easy to forget — see `inlineBudget`.
public enum CompletionMilestonePolicy {
  /// Every Nth completion of the day earns a tally milestone.
  public static let tallyInterval = 10

  /// Shortest run of consecutive days that earns a streak milestone.
  ///
  /// Three rather than two: a two-day run is "yesterday and today", which
  /// happens constantly and would make the rarest-looking celebration in the
  /// app one of the most frequent.
  public static let streakMinimum = 3

  /// Ceiling for the *blocking* half of a celebration.
  ///
  /// `TaskMutationService.markCurrentTaskDone` runs the feedback before the
  /// close request and abandons the close if it returns false, so time spent
  /// here is time the mutation is delayed and the cancel window is open. The
  /// current shipped sequence is ~210ms; this is the line a preset must not
  /// cross, or completing tasks starts to feel *slower* for being prettier.
  public static let inlineBudget: TimeInterval = 0.22

  /// Ceiling for the non-blocking half, which runs after the mutation has been
  /// dispatched and therefore delays nothing.
  public static let flourishBudget: TimeInterval = 0.5

  /// Precedence: `listCleared` > `dailyStreak` > `dailyTicked` > `dailyTally` >
  /// `ordinary`.
  ///
  /// Clearing the list wins because it is the rarest and most legible of them;
  /// a tally that coincides with it is absorbed rather than queued behind it.
  /// The streak sits second because it is the next rarest — it can only fire on
  /// the first completion of a day — and it outranks `dailyTicked` for the same
  /// reason: a daily tick happens several times every morning.
  ///
  /// - Parameters:
  ///   - kind: what was completed.
  ///   - remainingVisibleTaskCount: visible tasks *before* the optimistic
  ///     removal, so the last task in the list is `1`, not `0`. Ignored for
  ///     dailies, which live in a different list.
  ///   - ordinal: which completion of the day this one is, counting from 1.
  ///     Deliberately 1-based-including-this-one rather than "how many came
  ///     before": the task path asks before recording and the daily path asks
  ///     after, so a "before" count would mean something different at each call
  ///     site. Each caller converts once, here it means one thing.
  ///   - streakDays: consecutive days ending today, today included, on which
  ///     something was completed. Zero means "not known", which is what a
  ///     caller without a day log passes.
  public static func milestone(
    for kind: CompletionKind,
    remainingVisibleTaskCount: Int,
    ordinal: Int,
    streakDays: Int = 0
  ) -> CompletionMilestone {
    // The Rust core's `progress::completion_milestone`, which holds the
    // precedence; `tallyInterval` and `streakMinimum` are its constants.
    switch completionMilestone(
      isDaily: !kind.isTask, remainingVisibleTaskCount: Int64(remainingVisibleTaskCount),
      ordinal: Int64(ordinal), streakDays: Int64(streakDays))
    {
    case .ordinary: return .ordinary
    case .listCleared: return .listCleared
    case .dailyTicked: return .dailyTicked
    case .dailyTally(let count): return .dailyTally(count: Int(count))
    case .dailyStreak(let days): return .dailyStreak(days: Int(days))
    }
  }

  /// Multiplier applied to every duration in a celebration.
  ///
  /// Reduced motion collapses durations rather than removing the animation
  /// outright, so a row still resolves from "striking" to "struck" instead of
  /// teleporting between the two. Not zero: a zero-length spring can leave
  /// SwiftUI without a frame to interpolate, and the haptics — which are not
  /// motion and stay on regardless — would then land against nothing.
  public static func durationScale(reduceMotion: Bool) -> Double {
    reduceMotion ? 0.25 : 1.0
  }

  /// How long a flourish may run, reduced-motion scale applied.
  ///
  /// The inline half went through `clampedDuration` from the day it shipped;
  /// the flourish half read `flourishBudget` raw. So Reduce Motion collapsed
  /// the row's 180ms and then let a half-second particle burst play over the
  /// top of it — the loudest motion in the app was the one piece of it that
  /// ignored the setting. Every flourish takes its duration from here.
  public static func flourishDuration(reduceMotion: Bool) -> TimeInterval {
    clampedDuration(flourishBudget, budget: flourishBudget, reduceMotion: reduceMotion)
  }

  /// Clamps a preset's requested duration to the budget for its phase, after
  /// applying the reduced-motion scale. A plugin cannot opt out of this.
  ///
  /// Prefer `CelebrationScript.fitting` for a *sequence*: this clamps one
  /// duration in isolation, so a preset calling it per step can satisfy every
  /// clamp and still overrun the budget several times over.
  public static func clampedDuration(
    _ requested: TimeInterval,
    budget: TimeInterval,
    reduceMotion: Bool
  ) -> TimeInterval {
    let scaled = requested * durationScale(reduceMotion: reduceMotion)
    return max(0, min(scaled, budget))
  }
}
