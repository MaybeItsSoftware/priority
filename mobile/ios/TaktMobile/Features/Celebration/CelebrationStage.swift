import Observation
import TaktCore
import SwiftUI
import UIKit

/// The row being celebrated and where it is in its script. The Mac's
/// `CelebrationStage`: one row at a time, driven by the chosen style's
/// `CelebrationScript`, and read by every row through `.celebrationRow` and
/// `.celebrationIcon`.
@MainActor
@Observable
final class CelebrationStage {
  private(set) var taskID: String?
  private(set) var phase: CelebrationPhase = .idle
  private(set) var style: CelebrationStyle = .none
  /// Moves each time a script starts, so a burst redraws for a second
  /// completion of the same row.
  private(set) var run = 0

  /// Overridable for tests; the system setting otherwise.
  @ObservationIgnored var reduceMotion: () -> Bool = { UIAccessibility.isReduceMotionEnabled }

  var isPlaying: Bool { taskID != nil }

  func phase(for id: String) -> CelebrationPhase {
    taskID == id ? phase : .idle
  }

  /// Plays `style`'s script on `id`'s row, then returns. Each beat is
  /// entered with the Mac's curves (`CelebrationMotion`), scaled the same way
  /// for Reduce Motion.
  func play(_ style: CelebrationStyle, on id: String) async {
    let reduce = reduceMotion()
    let script = style.script(reduceMotion: reduce)
    guard !script.steps.isEmpty else { return }
    self.style = style
    taskID = id
    run &+= 1
    for step in script.steps {
      withAnimation(CelebrationCurves.phase(step.phase, reduceMotion: reduce)) { phase = step.phase }
      try? await Task.sleep(for: .seconds(step.duration))
    }
    phase = .idle
    taskID = nil
  }
}

/// The Mac's `CelebrationMotion`, for the phone. Every duration goes through
/// `CompletionMilestonePolicy.durationScale`, so Reduce Motion shortens the
/// motion rather than removing it.
enum CelebrationCurves {
  static func scaled(_ seconds: Double, _ reduceMotion: Bool) -> Double {
    seconds * CompletionMilestonePolicy.durationScale(reduceMotion: reduceMotion)
  }

  static func phase(_ phase: CelebrationPhase, reduceMotion: Bool) -> Animation {
    switch phase {
    case .anticipating: .easeOut(duration: scaled(0.05, reduceMotion))
    case .celebrating, .idle: row(reduceMotion: reduceMotion)
    }
  }

  static func row(reduceMotion: Bool) -> Animation {
    .spring(response: scaled(0.24, reduceMotion), dampingFraction: 0.72)
  }

  static func icon(reduceMotion: Bool) -> Animation {
    .spring(response: scaled(0.26, reduceMotion), dampingFraction: 0.5)
  }

  static func strike(reduceMotion: Bool) -> Animation {
    .easeOut(duration: scaled(0.12, reduceMotion))
  }
}

@MainActor
extension WorkspaceModel {
  /// Completes a task the way a tap on its box does: the chosen celebration
  /// plays on the row first, inside the shared 220ms budget, then the write
  /// lands. Reopening, and the None style, write at once.
  func completeCelebrating(_ taskID: String, defaults: UserDefaults = .standard) {
    guard celebration.taskID != taskID else { return }
    let style = CelebrationStyle.stored(in: defaults)
    guard style != .none, task(taskID)?.status == .open else {
      toggleComplete(taskID)
      return
    }
    Task { @MainActor in
      await celebration.play(style, on: taskID)
      toggleComplete(taskID)
    }
  }

  /// As `completeCelebrating`, for a write other than a plain completion — a
  /// daily's tick, a ladder rung finished without a session.
  func celebrate(_ taskID: String, defaults: UserDefaults = .standard, then write: @escaping @MainActor () -> Void) {
    guard celebration.taskID != taskID else { return }
    let style = CelebrationStyle.stored(in: defaults)
    guard style != .none else {
      write()
      return
    }
    Task { @MainActor in
      await celebration.play(style, on: taskID)
      write()
    }
  }
}

// MARK: - Rendering

/// The row half of a celebration: tint, scale, the rule drawn through, the
/// fold. Read from `CelebrationRowTreatment` per phase, so every surface
/// draws a preset the same way.
private struct CelebrationRowModifier: ViewModifier {
  @Environment(\.theme) private var theme
  @Environment(WorkspaceModel.self) private var model
  let taskID: String

  func body(content: Content) -> some View {
    let stage = model.celebration
    let phase = stage.phase(for: taskID)
    let treatment = stage.style.treatment
    content
      .opacity(treatment.fades(at: phase) ? 0.15 : 1)
      .scaleEffect(treatment.rowScale(for: phase))
      .scaleEffect(x: 1, y: treatment.collapses(at: phase) ? 0.2 : 1, anchor: .top)
      .background(theme.success.opacity(treatment.tintOpacity(for: phase)))
      .overlay(alignment: .leading) {
        if treatment.marksLeadingEdge(at: phase) {
          Rectangle().fill(theme.success).frame(width: 2)
        }
      }
  }
}

/// The rule drawn through a title, left to right, while the row celebrates.
private struct CelebrationStrikeModifier: ViewModifier {
  @Environment(\.theme) private var theme
  @Environment(WorkspaceModel.self) private var model
  let taskID: String

  func body(content: Content) -> some View {
    let stage = model.celebration
    let drawn = stage.style.treatment.drawsStrikethrough && stage.phase(for: taskID) == .celebrating
    content.overlay(alignment: .leading) {
      Rectangle()
        .fill(theme.success)
        .frame(height: 1.5)
        .scaleEffect(x: drawn ? 1 : 0, anchor: .leading)
        .opacity(drawn ? 1 : 0)
        .animation(CelebrationCurves.strike(reduceMotion: stage.reduceMotion()), value: drawn)
        .allowsHitTesting(false)
    }
  }
}

/// The status glyph's wind-up and pop, and Spark's burst from it.
private struct CelebrationIconModifier: ViewModifier {
  @Environment(WorkspaceModel.self) private var model
  let taskID: String

  func body(content: Content) -> some View {
    let stage = model.celebration
    let phase = stage.phase(for: taskID)
    content
      .scaleEffect(stage.style.treatment.iconScale(for: phase))
      .animation(CelebrationCurves.icon(reduceMotion: stage.reduceMotion()), value: phase)
      .overlay {
        if stage.style == .spark, phase == .celebrating {
          SparkBurst(seed: UInt64(truncatingIfNeeded: taskID.hashValue) &+ UInt64(stage.run),
                     reduceMotion: stage.reduceMotion())
            .allowsHitTesting(false)
        }
      }
  }
}

/// A few sparks thrown from the checkbox. Deterministic per seed, so a
/// redraw mid-burst does not reshuffle it — the Mac's `SparkBurst`.
private struct SparkBurst: View {
  @Environment(\.theme) private var theme
  let seed: UInt64
  let reduceMotion: Bool
  @State private var progress: Double = 0

  private static let count = 12

  var body: some View {
    Canvas { context, size in draw(in: &context, size: size) }
    .frame(width: 64, height: 64)
    .onAppear {
      withAnimation(.easeOut(duration: CelebrationCurves.scaled(0.3, reduceMotion))) { progress = 1 }
    }
  }

  private func draw(in context: inout GraphicsContext, size: CGSize) {
    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    let t: Double = progress
    context.opacity = 1 - t
    for index in 0..<Self.count {
      let base: Double = Double(index) / Double(Self.count) * 2 * Double.pi
      let angle: Double = base + Self.noise(seed, index, 1) * 0.5
      let reach: Double = 14 + 16 * Self.noise(seed, index, 2)
      let distance: Double = reach * t
      let size: Double = 1.2 + 1.3 * Self.noise(seed, index, 3)
      let radius: Double = size * (1 - t * 0.6)
      let x: Double = Double(center.x) + cos(angle) * distance
      let y: Double = Double(center.y) + sin(angle) * distance
      let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
      let colour: Color = Self.noise(seed, index, 4) > 0.5 ? theme.success : theme.warning
      context.fill(Path(ellipseIn: rect), with: .color(colour))
    }
  }

  /// A stable 0…1 from (seed, index, salt).
  static func noise(_ seed: UInt64, _ index: Int, _ salt: UInt64) -> Double {
    let golden: UInt64 = 0x9E37_79B9_7F4A_7C15
    let mixer: UInt64 = 0xBF58_476D_1CE4_E5B9
    let spread: UInt64 = UInt64(index) &* golden
    let salted: UInt64 = salt &* mixer
    var value: UInt64 = seed &+ spread &+ salted
    value ^= value >> 30
    value &*= mixer
    value ^= value >> 27
    value &*= 0x94D0_49BB_1331_11EB
    value ^= value >> 31
    return Double(value % 10_000) / 10_000
  }
}

extension View {
  /// Draws the row half of a celebration on the row for `taskID`.
  func celebrationRow(_ taskID: String) -> some View { modifier(CelebrationRowModifier(taskID: taskID)) }
  /// Draws the rule through the title of `taskID` while it celebrates.
  func celebrationStrike(_ taskID: String) -> some View { modifier(CelebrationStrikeModifier(taskID: taskID)) }
  /// Pops the status glyph of `taskID`, and throws Spark's burst from it.
  func celebrationIcon(_ taskID: String) -> some View { modifier(CelebrationIconModifier(taskID: taskID)) }
}
