import PriorityCore
import SwiftUI

/// The row folds shut and fades rather than being struck through.
///
/// Where `Strike` annotates the row and then removes it, this makes the removal
/// itself the effect — the gap closing is what tells you the task is gone. It
/// suits long lists, where a line drawn through row six is easy to miss but the
/// list settling upward is not.
@MainActor
final class FoldCelebrationPlugin: CompletionCelebrationPlugin {
  let pluginIdentifier = "native.celebration.fold"
  let displayName = "Fold"
  let pluginDescription = "The row folds away and the list closes over it."
  let celebrationIconSystemName = "arrow.down.right.and.arrow.up.left"
  let rowTreatment = CelebrationRowTreatment.fold

  /// A beat at full height before the collapse, so it reads as a fold rather
  /// than a jump cut. Longer than `Strike`'s wind-up for that reason.
  private static let settle: TimeInterval = 0.04
  private static let collapse: TimeInterval = 0.13

  func inlineScript(for event: CompletionEvent, reduceMotion: Bool) -> CelebrationScript {
    CelebrationScript.fitting(
      [
        .init(phase: .anticipating, duration: Self.settle),
        .init(phase: .celebrating, duration: Self.collapse),
      ],
      budget: CompletionMilestonePolicy.inlineBudget,
      reduceMotion: reduceMotion
    )
  }

  func celebrationSound(for event: CompletionEvent) -> CelebrationSound? {
    event.milestone.earnsFlourish ? .milestone : .soft
  }

  func makeFlourish(_ event: CompletionEvent) -> AnyView? {
    guard event.milestone.earnsFlourish else { return nil }
    return AnyView(FoldFlourish(milestone: event.milestone))
  }
}

/// A soft wash that settles down the panel, echoing the row's collapse at the
/// scale of the whole list.
private struct FoldFlourish: View {
  let milestone: CompletionMilestone
  @Environment(AppCoordinator.self) private var manager
  @Environment(\.theme) private var theme
  @State private var settled = false

  var body: some View {
    let tint = manager.preferences.themeColor(for: .success)
    // Scaled by the occasion rather than fixed: a daily tick gets a hint, a
    // cleared list gets something you would notice from across the desk.
    let peak = 0.10 + 0.22 * milestone.flourishWeight

    ZStack {
      LinearGradient(
        colors: [tint.opacity(settled ? 0 : peak), .clear],
        startPoint: .top,
        endPoint: .bottom
      )
      if let caption = milestone.caption {
        VStack {
          Spacer(minLength: 0)
          Text(caption.uppercased())
            .font(theme.monoFont(size: theme.type.microLabel.size, weight: .bold))
            .tracking(theme.microLabelTracking)
            .foregroundColor(tint)
          Spacer(minLength: 0)
        }
      }
    }
    .opacity(settled ? 0 : 1)
    .onAppear {
      withAnimation(CelebrationMotion.flourish(reduceMotion: manager.celebration.prefersReducedMotion)) {
        settled = true
      }
    }
  }
}
