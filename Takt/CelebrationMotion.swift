import TaktCore
import SwiftUI

/// The curves a completion animates on, in one place.
///
/// Every surface that renders a completing row — the task list, the Daily
/// checklist, the kanban card — used to spell its own `.spring(response: 0.3,
/// dampingFraction: 0.5)` inline. Two problems came out of that. The obvious
/// one is drift: the surfaces could disagree about how a completion feels, and
/// they did — the kanban card was still on the pre-retune spring long after the
/// list rows had moved off it. The subtle one is that a curve written at the
/// call site tends to be written *once*, on the one modifier the author was
/// thinking about, leaving the row's tint and its leading bar to snap while its
/// scale springs.
///
/// The timings are deliberately shorter than the ones they replace.
/// `CompletionMilestonePolicy.inlineBudget` caps the whole blocking sequence at
/// 220ms, and a 300ms spring inside a 210ms window is a spring that is
/// interrupted in both directions and never resolves — which is what made the
/// effect read as a twitch rather than as a motion.
enum CelebrationMotion {

  /// The curve for entering `phase`.
  ///
  /// Anticipation gets a short ease rather than a spring on purpose: it is two
  /// frames of wind-up, and a spring that overshoots the wind-up would put the
  /// row *above* its resting size on the way to squashing it, which is the
  /// opposite of the read.
  static func phase(_ phase: CelebrationPhase, reduceMotion: Bool) -> Animation {
    switch phase {
    case .anticipating:
      return .easeOut(duration: scaled(0.05, reduceMotion))
    case .celebrating, .idle:
      return row(reduceMotion: reduceMotion)
    }
  }

  /// The row itself: scale, tint, leading bar. Damped fairly high, because this
  /// is a large surface and a wobbly one draws attention to the animation
  /// instead of to what it means.
  static func row(reduceMotion: Bool) -> Animation {
    .spring(response: scaled(0.24, reduceMotion), dampingFraction: 0.72)
  }

  /// Changing what the plot is a window onto — zooming into a quadrant and
  /// back. Eased rather than sprung: the dots are moving because the *scale*
  /// changed, not because anything happened to them, and a spring would give
  /// that a bounce it has not earned. Lives here so it is scaled for reduced
  /// motion like everything else rather than carrying its own raw number.
  static func viewport(reduceMotion: Bool) -> Animation {
    .easeInOut(duration: scaled(0.22, reduceMotion))
  }

  /// The status glyph. Much looser — a small shape is where an overshoot reads
  /// as confidence rather than as slop, and this is the moment the completion
  /// is actually *felt*.
  static func icon(reduceMotion: Bool) -> Animation {
    .spring(response: scaled(0.26, reduceMotion), dampingFraction: 0.5)
  }

  /// The strikethrough sweeping across the title. Linear-ish rather than
  /// springy: a line being drawn should not overshoot the end of the word and
  /// come back.
  ///
  /// `width` is the title's measured width. A fixed duration made the rule's
  /// *speed* depend on how long the task was: three words got a 120ms flash
  /// across forty points, twelve words got the same 120ms across four hundred,
  /// and neither read as a pen being drawn through. Holding the speed roughly
  /// constant and letting the duration follow the width is what a struck line
  /// actually does. Clamped at both ends so a one-word task still registers and
  /// a very long one does not eat the budget.
  static func strike(reduceMotion: Bool, width: CGFloat = 0) -> Animation {
    .easeOut(duration: strikeDuration(reduceMotion: reduceMotion, width: width))
  }

  /// Points per second the rule travels. Tuned against the 13pt task font: a
  /// typical two-thirds-width row lands near the 140ms the fixed duration used
  /// to spend on every row regardless.
  private static let strikeSpeed: CGFloat = 1400

  static func strikeDuration(reduceMotion: Bool, width: CGFloat) -> TimeInterval {
    let travel = width > 0 ? TimeInterval(width / strikeSpeed) : 0.14
    return scaled(min(max(travel, 0.07), 0.2), reduceMotion)
  }

  /// The post-mutation half. Scaled for reduced motion like everything else —
  /// which it demonstrably was not before, being the one animation in the app
  /// that read its budget raw.
  static func flourish(reduceMotion: Bool) -> Animation {
    .easeOut(duration: CompletionMilestonePolicy.flourishDuration(reduceMotion: reduceMotion))
  }

  /// Rows sliding up to close the gap left by a completed one.
  ///
  /// Slower and softer than the row's own celebration: this is the list
  /// settling, not the completion itself, and it plays after the mutation has
  /// gone out so it costs the inline budget nothing.
  static func listSettle(reduceMotion: Bool) -> Animation {
    .spring(response: scaled(0.32, reduceMotion), dampingFraction: 0.85)
  }

  /// Reduced motion collapses durations rather than removing the animation, so
  /// a row still resolves between states instead of teleporting. Same rule, and
  /// the same reasoning, as `CompletionMilestonePolicy.durationScale`, which is
  /// where the factor comes from.
  private static func scaled(_ duration: TimeInterval, _ reduceMotion: Bool) -> TimeInterval {
    duration * CompletionMilestonePolicy.durationScale(reduceMotion: reduceMotion)
  }
}
