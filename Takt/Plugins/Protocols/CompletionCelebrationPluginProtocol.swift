import TaktCore
import SwiftUI

/// What a celebration is allowed to touch while it runs.
///
/// Presets drive the row through this rather than reaching for the completing
/// flag directly, because that flag has moved once already and will move again
/// — and because a preset has no business knowing whether a row is a task or a
/// daily beyond the `CompletionKind` it was handed.
@MainActor
protocol CelebrationStage: AnyObject {
  /// Moves a row to `phase`. Passing `.idle` (or a `nil` kind) ends the
  /// sequence and returns the row to its ordinary appearance.
  func setPhase(_ phase: CelebrationPhase, for kind: CompletionKind?)
  /// Whether the system asked for reduced motion. Presets should route their
  /// durations through `CelebrationScript.fitting` rather than branching on
  /// this themselves.
  var prefersReducedMotion: Bool { get }
}

/// A swappable "what completing something looks like".
///
/// Motion and sound, since a `CelebrationSound` was folded in — but *not*
/// haptics, which stay outside this protocol and fire for every completion
/// regardless of the chosen preset. They say "the app heard you", which is not
/// the same job as celebrating, and a user who turns the celebration off should
/// not also lose the confirmation.
///
/// The members split along the one axis that matters here: `inlineScript` is
/// played *before* the close request goes out and can cancel it, whereas
/// `makeFlourish` renders after the mutation is already on its way and so can
/// afford to be showier. See `CompletionMilestonePolicy.inlineBudget`.
@MainActor
protocol CompletionCelebrationPlugin: Plugin {
  /// SF Symbol shown next to the preset's name in the picker.
  var celebrationIconSystemName: String { get }

  /// How the row renders while this preset's inline phase is running.
  ///
  /// Data rather than a view so every preset shares one row layout — see
  /// `CelebrationRowTreatment`.
  var rowTreatment: CelebrationRowTreatment { get }

  /// The timing of the blocking half, as data.
  ///
  /// Returning a script rather than running the sequence by hand is what makes
  /// a preset's timing checkable: `Native/Celebration/` is excluded from the
  /// `TaktPlugins` target because celebrations are SwiftUI, so anything a
  /// preset expresses in `Task.sleep` calls is unreachable from every test.
  /// Build it with `CelebrationScript.fitting`, which applies the reduced-motion
  /// scale and the budget in one place, to the total rather than to each step.
  func inlineScript(for event: CompletionEvent, reduceMotion: Bool) -> CelebrationScript

  /// The tick that plays alongside the inline phase, if this preset has one and
  /// the user has asked for sound. `nil` is silence.
  ///
  /// Data rather than playback so the preset does not decide *whether* it is
  /// heard — `CompletionCelebrationManager` checks the preference, and the
  /// preference is off by default.
  func celebrationSound(for event: CompletionEvent) -> CelebrationSound?

  /// Optional decoration drawn over the completing row itself, for presets that
  /// need more than `rowTreatment` can express (particles, say). Distinct from
  /// `makeFlourish`, which outlives the row.
  func makeRowAccent(for kind: CompletionKind) -> AnyView?

  /// The blocking half. Must return within
  /// `CompletionMilestonePolicy.inlineBudget`.
  ///
  /// Defaulted: the default plays `inlineScript` and is what all four shipped
  /// presets use. Override only for something a schedule genuinely cannot
  /// express, and expect `CompletionCelebrationManager` to stop waiting on you
  /// at the budget either way.
  ///
  /// Returns `false` when the sequence was cancelled — the user navigated away
  /// or switched tasks mid-animation — in which case the caller abandons the
  /// close rather than firing it late. Implementations must let
  /// `CancellationError` out of their sleeps for this to work.
  func runInline(_ event: CompletionEvent, stage: any CelebrationStage) async -> Bool

  /// The non-blocking half, drawn in the popover's overlay layer once the
  /// mutation has been dispatched. `nil` means "nothing extra for this event",
  /// which is the right answer for `.ordinary`.
  ///
  /// It renders in the overlay rather than the row because by this point the
  /// row is gone: `applyOptimisticCompletion` has already removed the subtree.
  func makeFlourish(_ event: CompletionEvent) -> AnyView?
}

extension CompletionCelebrationPlugin {
  /// Most presets are inline-only; opting into a flourish is the exception.
  func makeFlourish(_ event: CompletionEvent) -> AnyView? { nil }
  /// Likewise: most presets say everything they need to through `rowTreatment`.
  func makeRowAccent(for kind: CompletionKind) -> AnyView? { nil }
  /// And most are silent.
  func celebrationSound(for event: CompletionEvent) -> CelebrationSound? { nil }

  /// Plays `inlineScript` against the stage.
  ///
  /// The one place `withAnimation` meets a celebration's timing, which is the
  /// point of scripting them: the four presets used to spell this loop out
  /// individually, and each spelled it slightly differently — one cleared the
  /// row with an unspecified default animation, one hardcoded a spring that
  /// ignored reduced motion, and all three of them clamped their sleeps one at
  /// a time against a budget that was meant to bound the sum.
  func runInline(_ event: CompletionEvent, stage: any CelebrationStage) async -> Bool {
    let reduceMotion = stage.prefersReducedMotion
    let script = inlineScript(for: event, reduceMotion: reduceMotion)
    guard !script.steps.isEmpty else { return true }

    for step in script.steps {
      withAnimation(CelebrationMotion.phase(step.phase, reduceMotion: reduceMotion)) {
        stage.setPhase(step.phase, for: event.kind)
      }
      do {
        try await Task.sleep(for: .seconds(step.duration))
      } catch {
        // Cancellation means the user moved on mid-animation. Clear the row and
        // report it, so the caller drops the close instead of firing it late.
        withAnimation(CelebrationMotion.row(reduceMotion: reduceMotion)) {
          stage.setPhase(.idle, for: nil)
        }
        return false
      }
    }
    withAnimation(CelebrationMotion.row(reduceMotion: reduceMotion)) {
      stage.setPhase(.idle, for: nil)
    }
    return true
  }
}
