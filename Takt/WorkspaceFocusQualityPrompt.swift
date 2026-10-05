import TaktCore
import TaktWorkspace
import SwiftUI

/// The one question asked at the end of a focus block: how did that go?
///
/// It is deliberately the only thing on screen, and deliberately answerable
/// with a single key. A block is worth the minutes it took multiplied by this
/// answer, and the running total is shown while choosing, so the cost of
/// flattering yourself is visible at the moment you would do it.
struct WorkspaceFocusQualityPrompt: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let pending: WorkspaceViewModel.PendingFocusCompletion
  /// Nil when the prompt is filling a surface that already has a width — the
  /// summoned panel, where it is the whole of what is on screen.
  var fixedWidth: CGFloat? = 500

  @State private var quality: FocusQuality = .solid
  @State private var customMultiplier: Double = FocusQuality.solid.multiplier
  @State private var isCustom = false

  private var multiplier: Double {
    isCustom ? FocusPoints.clamped(multiplier: customMultiplier) : quality.multiplier
  }

  private var points: Double {
    FocusPoints.score(seconds: pending.seconds, multiplier: multiplier)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: theme.space.lg) {
      header
      qualityChoices
      customRow
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
    .onExitCommand { model.cancelFocusCompletion() }
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

  private var qualityChoices: some View {
    VStack(spacing: theme.space.xxs) {
      ForEach(Array(FocusQuality.allCases.enumerated()), id: \.element) { index, option in
        let isChosen = !isCustom && quality == option
        Button {
          quality = option
          isCustom = false
        } label: {
          HStack(spacing: theme.space.sm) {
            // The key that picks it, drawn as a key.
            KeyCap("\(index + 1)")
            VStack(alignment: .leading, spacing: 0) {
              Text(option.title)
                .font(theme.bodyFont())
                .foregroundStyle(theme.ink)
              Text(option.detail)
                .font(theme.captionFont)
                .foregroundStyle(theme.muted)
            }
            Spacer()
            Text("×\(FocusPoints.formatted(option.multiplier))")
              .font(theme.numeralFont(theme.scale.body))
              .monospacedDigit()
              .foregroundStyle(isChosen ? theme.primary : theme.muted)
          }
          .padding(.vertical, theme.space.xs)
          .padding(.horizontal, theme.space.sm)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
          .background(
            isChosen ? theme.selectionFill : Color.clear,
            in: RoundedRectangle(cornerRadius: theme.controlRadius))
        }
        .buttonStyle(.plain)
        .focusable()
        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
        .accessibilityLabel("\(option.title), \(option.detail)")
      }
    }
  }

  private var customRow: some View {
    HStack(spacing: theme.space.sm) {
      Toggle("Something else", isOn: $isCustom)
        .toggleStyle(.switch)
        .tint(theme.primary)
        .font(theme.bodyFont())
        .foregroundStyle(theme.ink)
        .focusable()
      Stepper(
        value: $customMultiplier,
        in: FocusPoints.multiplierRange,
        step: 0.25
      ) {
        Text("×\(FocusPoints.formatted(customMultiplier))")
          .font(theme.numeralFont(theme.scale.body))
          .monospacedDigit()
          .foregroundStyle(isCustom ? theme.primary : theme.muted)
      }
      .focusable()
      .disabled(!isCustom)
      Spacer()
    }
    .onChange(of: customMultiplier) { _, _ in isCustom = true }
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
      Text("1–5 choose · ↩ log it · esc keep working")
        .font(theme.captionFont)
        .foregroundStyle(theme.dim)
      Spacer()
      Button("Keep working") { model.cancelFocusCompletion() }
        .buttonStyle(FocusActionButtonStyle())
        .focusable()
        .keyboardShortcut(.cancelAction)
      Button("Log it") { model.confirmFocusCompletion(multiplier: multiplier) }
        .buttonStyle(FocusActionButtonStyle(prominent: true))
        .focusable()
        .keyboardShortcut(.defaultAction)
    }
  }
}
