import TaktCore
import TaktWorkspace
import SwiftUI

/// The one question asked at the end of a focus block: how did that go?
///
/// It is deliberately the only thing on screen, and answered with the arrow
/// keys. The block is worth the minutes it took times this multiplier, which
/// starts at ×1.0 — an ordinary block — and moves a tenth at a time, so the
/// answer is a small adjustment from "it was fine" rather than a pick from a
/// menu of adjectives. The running total is shown while choosing, so the cost
/// of flattering yourself is visible at the moment you would do it.
struct WorkspaceFocusQualityPrompt: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let pending: WorkspaceViewModel.PendingFocusCompletion
  /// Nil when the prompt is filling a surface that already has a width — the
  /// summoned panel, where it is the whole of what is on screen.
  var fixedWidth: CGFloat? = 500

  /// Tenths, so that ten presses of ↑ land on exactly ×2.0 rather than on
  /// whatever ten additions of 0.1 come to in binary.
  @State private var tenths = 10
  @FocusState private var hasKeyboard: Bool

  private static let step = 1
  private static var tenthsRange: ClosedRange<Int> {
    Int(FocusPoints.multiplierRange.lowerBound * 10)...Int(FocusPoints.multiplierRange.upperBound * 10)
  }

  private var multiplier: Double { Double(tenths) / 10 }

  private var points: Double {
    FocusPoints.score(seconds: pending.seconds, multiplier: multiplier)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: theme.space.lg) {
      header
      dial
      FocusRule()
      tally
      actions
    }
    .padding(theme.space.xl)
    .frame(width: fixedWidth)
    // Raised when it is a sheet over the window, the page when it fills the
    // panel: an overlay sits above the paper, a surface of its own does not.
    .background(fixedWidth == nil ? theme.paper : theme.raised)
    .interactiveDismissDisabled()
    .focusable()
    .focusEffectDisabled()
    .focused($hasKeyboard)
    .onKeyPress(.upArrow) { nudge(by: Self.step); return .handled }
    .onKeyPress(.downArrow) { nudge(by: -Self.step); return .handled }
    // A menial task, or a block that should not count for some other reason:
    // one key logs it at nothing, without stepping the dial down ten times.
    .onKeyPress(characters: ["\\"]) { _ in
      model.confirmFocusCompletion(multiplier: 0)
      return .handled
    }
    .onAppear { hasKeyboard = true }
    .onExitCommand { model.cancelFocusCompletion() }
  }

  private func nudge(by delta: Int) {
    let range = Self.tenthsRange
    tenths = min(max(tenths + delta, range.lowerBound), range.upperBound)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: theme.space.xs) {
      MicroLabel(pending.completeTask ? "Complete task · how did that go?" : "Log progress · how did that go?")
      Text(pending.title)
        .font(theme.titleFont)
        .foregroundStyle(theme.ink)
        .lineLimit(2)
        .truncationMode(.tail)
        .help(pending.title)
      Text("\(FocusPoints.formatted(pending.minutes)) minutes of focused work")
        .font(theme.captionFont)
        .monospacedDigit()
        .foregroundStyle(theme.muted)
    }
  }

  /// The multiplier, large, between the two buttons that move it. Always one
  /// decimal place, so ×1.0 and ×1.1 read as neighbours rather than as a
  /// whole number and a fraction.
  private var dial: some View {
    HStack(spacing: theme.space.md) {
      stepButton("minus", help: "Less (↓)", enabled: tenths > Self.tenthsRange.lowerBound) {
        nudge(by: -Self.step)
      }
      Text("×" + String(format: "%.1f", multiplier))
        .font(theme.numeralFont(theme.scale.display, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(tenths == 10 ? theme.ink : theme.primary)
        .contentTransition(.numericText(value: multiplier))
        .animation(.snappy, value: tenths)
        .frame(minWidth: 120)
        .accessibilityLabel("Multiplier \(String(format: "%.1f", multiplier))")
        .accessibilityAdjustableAction { direction in
          switch direction {
          case .increment: nudge(by: Self.step)
          case .decrement: nudge(by: -Self.step)
          @unknown default: break
          }
        }
      stepButton("plus", help: "More (↑)", enabled: tenths < Self.tenthsRange.upperBound) {
        nudge(by: Self.step)
      }
      Spacer(minLength: 0)
      if tenths != 10 {
        Button("Reset") { tenths = 10 }
          .buttonStyle(FocusActionButtonStyle())
          .focusable(false)
          .help("Back to ×1.0")
      }
    }
  }

  private func stepButton(
    _ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
    }
    .buttonStyle(FocusActionButtonStyle())
    .focusable(false)
    .disabled(!enabled)
    .help(help)
    .accessibilityLabel(help)
  }

  private var tally: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: theme.space.xxs) {
        MicroLabel("This block")
        Text("\(FocusPoints.formatted(points)) pts")
          .font(theme.numeralFont(theme.scale.display))
          .monospacedDigit()
          .foregroundStyle(theme.primary)
          .contentTransition(.numericText())
          .animation(.snappy, value: points)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: theme.space.xxs) {
        MicroLabel("Today")
        Text("\(FocusPoints.formatted(model.focusPoints.today + points)) pts")
          .font(theme.numeralFont(theme.scale.title))
          .monospacedDigit()
          .foregroundStyle(theme.ink)
      }
    }
  }

  private var actions: some View {
    HStack(spacing: theme.space.sm) {
      Text("↑ ↓ adjust by 0.1 · ↩ log it · \\ log at ×0 · esc keep working")
        .font(theme.captionFont)
        .foregroundStyle(theme.dim)
      Spacer()
      Button("Keep working") { model.cancelFocusCompletion() }
        .buttonStyle(FocusActionButtonStyle())
        .focusable(false)
        .keyboardShortcut(.cancelAction)
      Button("Log it") { model.confirmFocusCompletion(multiplier: multiplier) }
        .buttonStyle(FocusActionButtonStyle(prominent: true))
        .focusable(false)
        .keyboardShortcut(.defaultAction)
    }
  }
}
