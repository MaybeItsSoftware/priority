import PriorityCore
import SwiftUI

/// A burst of sparks along the row as it completes.
///
/// The showiest of the presets, and the only one that draws anything the row
/// couldn't express by itself — hence `makeRowAccent`. Particles are drawn in a
/// single `Canvas` rather than as a stack of views: at twenty-odd sparks the
/// view-per-particle version costs more in layout than the effect is worth.
@MainActor
final class SparkCelebrationPlugin: CompletionCelebrationPlugin {
  let pluginIdentifier = "native.celebration.spark"
  let displayName = "Spark"
  let pluginDescription = "Sparks scatter along the row as it completes."
  let celebrationIconSystemName = "sparkles"
  let rowTreatment = CelebrationRowTreatment.spark

  /// The deepest wind-up of the three presets, because it precedes the biggest
  /// pop — the glyph squashes to 0.84 before the particles leave it.
  private static let leadIn: TimeInterval = 0.03
  private static let burst: TimeInterval = 0.15

  func inlineScript(for event: CompletionEvent, reduceMotion: Bool) -> CelebrationScript {
    CelebrationScript.fitting(
      [
        .init(phase: .anticipating, duration: Self.leadIn),
        .init(phase: .celebrating, duration: Self.burst),
      ],
      budget: CompletionMilestonePolicy.inlineBudget,
      reduceMotion: reduceMotion
    )
  }

  func celebrationSound(for event: CompletionEvent) -> CelebrationSound? {
    event.milestone.earnsFlourish ? .milestone : .bright
  }

  func makeRowAccent(for kind: CompletionKind) -> AnyView? {
    AnyView(SparkBurst(seed: kind.sparkSeed, count: 18))
  }

  func makeFlourish(_ event: CompletionEvent) -> AnyView? {
    guard event.milestone.earnsFlourish else { return nil }
    // A milestone earns a denser burst across the panel rather than a different
    // idiom — same sparks, more of them, more room — with the count following
    // the occasion so a cleared list outshines a ticked daily.
    let count = Int(28 + 44 * event.milestone.flourishWeight)
    return AnyView(
      SparkBurst(seed: event.ordinal, count: count, caption: event.milestone.caption)
        .padding(.vertical, 24)
    )
  }
}

extension CompletionKind {
  /// A stable per-row seed, so two rows completing together don't scatter their
  /// sparks identically. `Math.random` is deliberately avoided — the pattern
  /// should be reproducible for a given row.
  fileprivate var sparkSeed: Int {
    switch self {
    case .task(let id): return id
    case .daily(let id), .workspaceTask(let id): return abs(id.hashValue % 9973)
    }
  }
}

/// Sparks thrown outward from the row's centre line, drawn in one `Canvas`.
///
/// The positions come from a small deterministic hash rather than
/// `Double.random`, so a given row always bursts the same way — a re-render
/// mid-animation would otherwise reshuffle every particle.
private struct SparkBurst: View {
  let seed: Int
  let count: Int
  var caption: String?

  @Environment(AppCoordinator.self) private var manager
  @Environment(\.theme) private var theme
  @State private var progress: Double = 0

  var body: some View {
    let tint = manager.preferences.themeColor(for: .success)
    let accent = manager.preferences.themeAccentColor

    ZStack {
      Canvas { context, size in
        guard progress > 0 else { return }
        for index in 0..<count {
          let noise = Self.noise(seed: seed, index: index)
          // Spread along the row, biased away from the very edges.
          let originX = size.width * (0.08 + 0.84 * noise.0)
          let originY = size.height * 0.5
          // Mostly sideways, a little vertical, so it reads as a scatter along
          // the line rather than a firework.
          let driftX = (noise.1 - 0.5) * size.width * 0.22
          let driftY = (noise.2 - 0.5) * size.height * 1.6

          let eased = 1 - pow(1 - progress, 2)
          let x = originX + driftX * eased
          let y = originY + driftY * eased
          let radius = (0.9 + noise.3 * 1.3) * (1 - progress)
          guard radius > 0.05 else { continue }

          let rect = CGRect(
            x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
          let color = noise.3 > 0.7 ? accent : tint
          context.fill(Path(ellipseIn: rect), with: .color(color.opacity(1 - progress)))
        }
      }
      if let caption {
        Text(caption)
          .font(theme.monoFont(size: theme.type.microLabel.size, weight: theme.type.microLabel.weight))
          .textCase(theme.microLabelIsUppercased ? .uppercase : nil)
          .tracking(theme.microLabelTracking)
          .foregroundColor(tint)
          .opacity(progress < 0.15 ? 0 : 1 - progress * 0.5)
      }
    }
    .onAppear {
      withAnimation(CelebrationMotion.flourish(reduceMotion: manager.celebration.prefersReducedMotion)) {
        progress = 1
      }
    }
  }

  /// Four decorrelated values in the range 0...1 from an integer pair.
  ///
  /// A hand-rolled hash rather than `SystemRandomNumberGenerator` because the
  /// result must be identical every time the view re-evaluates its body.
  private static func noise(seed: Int, index: Int) -> (Double, Double, Double, Double) {
    func mix(_ salt: Int) -> Double {
      var value = UInt64(bitPattern: Int64(seed &* 73_856_093 ^ index &* 19_349_663 ^ salt))
      value ^= value >> 33
      value = value &* 0xff51_afd7_ed55_8ccd
      value ^= value >> 33
      return Double(value % 10_000) / 10_000
    }
    return (mix(1), mix(2), mix(3), mix(4))
  }
}
