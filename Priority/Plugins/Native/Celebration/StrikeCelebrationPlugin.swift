import PriorityCore
import SwiftUI

/// The default: a line draws through the row, the checkmark pops, the row
/// takes a wash of success tint.
///
/// The timings started as a faithful port of the sequence that shipped inline
/// in `AppCoordinator+ServiceHosts` (30ms / 100ms / 80ms) and have since been
/// retuned twice. The first pass fixed the *shape*:
///
/// - The 30ms lead-in bought nothing. It was there so the strike "doesn't race
///   the keypress", but a completion that visibly waits before acknowledging
///   you is the one thing this sequence must never do.
/// - The strike drew for 100ms and then held for 80ms. Reversed emphasis: the
///   draw is the part carrying the meaning, so it got the extra time and the
///   hold was cut to the shortest beat that still registers as a pause.
/// - The whole thing ran on a 280ms spring inside a 210ms window, so the
///   animation was interrupted in both directions and never resolved.
///
/// The second pass put a *shorter* lead-in back, for the opposite reason to the
/// one that was removed. `anticipating` is not a delay before acknowledging the
/// keypress — the row moves on the first frame, it just moves the other way
/// first. 25ms of squash is what gives the pop somewhere to come from, and it
/// is the difference between a 180ms effect that reads as deliberate and one
/// that reads as a flicker.
@MainActor
final class StrikeCelebrationPlugin: CompletionCelebrationPlugin {
  let pluginIdentifier = "native.celebration.strike"
  let displayName = "Strike"
  let pluginDescription = "A line draws through the row as it completes."
  let celebrationIconSystemName = "strikethrough"
  let rowTreatment = CelebrationRowTreatment.strike

  /// Wind-up. Motion only — no tint, no rule.
  private static let anticipate: TimeInterval = 0.025
  /// Roughly how long the strikethrough takes to draw across the row.
  private static let strikeDraw: TimeInterval = 0.115
  /// Hold so the struck state is perceptible before the row is removed. Just
  /// long enough to register as a beat; any longer and it reads as lag.
  private static let hold: TimeInterval = 0.055

  func inlineScript(for event: CompletionEvent, reduceMotion: Bool) -> CelebrationScript {
    CelebrationScript.fitting(
      [
        .init(phase: .anticipating, duration: Self.anticipate),
        .init(phase: .celebrating, duration: Self.strikeDraw),
        .init(phase: .celebrating, duration: Self.hold),
      ],
      budget: CompletionMilestonePolicy.inlineBudget,
      reduceMotion: reduceMotion
    )
  }

  func celebrationSound(for event: CompletionEvent) -> CelebrationSound? {
    event.milestone.earnsFlourish ? .milestone : .tick
  }

  func makeFlourish(_ event: CompletionEvent) -> AnyView? {
    guard event.milestone.earnsFlourish else { return nil }
    return AnyView(StrikeFlourish(milestone: event.milestone))
  }
}

/// The milestone half: a rule sweeps across the panel and fades.
///
/// Deliberately the same gesture as the row's strikethrough, scaled up to the
/// width of the list, rather than a different idiom bolted on — but scaled by
/// `flourishWeight` rather than drawn identically for every occasion. Clearing
/// your entire list used to get the same 1.5pt hairline as ticking one daily,
/// which made the rarest event in the app quieter than the row that caused it.
private struct StrikeFlourish: View {
  let milestone: CompletionMilestone
  @Environment(AppCoordinator.self) private var manager
  @Environment(\.theme) private var theme
  @State private var progress: Double = 0

  private var tint: Color {
    manager.preferences.themeColor(for: .success)
  }

  /// 1.5pt for a daily tick up to 4pt for a cleared list.
  private var thickness: CGFloat {
    1.5 + 2.5 * milestone.flourishWeight
  }

  var body: some View {
    ZStack {
      // A wash behind the rule, and only for the occasions that have earned
      // one: below half weight this is fully transparent and the flourish is
      // the rule alone, exactly as it was.
      tint
        .opacity(max(0, milestone.flourishWeight - 0.5) * 0.24 * (1 - progress))

      VStack(spacing: 10) {
        Spacer(minLength: 0)
        Rectangle()
          .fill(tint.opacity(0.55))
          .frame(height: thickness)
          .scaleEffect(x: progress, y: 1, anchor: .leading)
          .opacity(1 - progress * 0.6)
        if let caption = milestone.caption {
          Text(caption)
            .font(theme.monoFont(size: theme.type.microLabel.size, weight: theme.type.microLabel.weight))
            .textCase(theme.microLabelIsUppercased ? .uppercase : nil)
            .tracking(theme.microLabelTracking)
            .foregroundColor(tint)
            .opacity(progress < 0.15 ? 0 : 1 - progress * 0.5)
        }
        Spacer(minLength: 0)
      }
    }
    .padding(.horizontal, Self.rowHorizontalPadding)
    .onAppear {
      withAnimation(CelebrationMotion.flourish(reduceMotion: manager.celebration.prefersReducedMotion)) {
        progress = 1
      }
    }
  }

  /// The strike is drawn over a task row, so it has to start and end where the
  /// row's text does. Held here as its own number now that `PopoverLayout` is
  /// gone; it was never the popover's measurement so much as a row's.
  private static let rowHorizontalPadding: CGFloat = 14
}
