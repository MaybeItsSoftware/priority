import PriorityWorkspace
import SwiftUI

/// The one question asked at the end of a focus block: how did that go?
///
/// It is deliberately the only thing on screen, and deliberately answerable
/// with a single key. A block is worth the minutes it took multiplied by this
/// answer, and the running total is shown while choosing, so the cost of
/// flattering yourself is visible at the moment you would do it.
struct WorkspaceFocusQualityPrompt: View {
  @Environment(WorkspaceViewModel.self) private var model
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
    VStack(alignment: .leading, spacing: 18) {
      header
      qualityChoices
      customRow
      Divider()
      tally
      actions
    }
    .padding(26)
    .frame(width: fixedWidth)
    .interactiveDismissDisabled()
    .onExitCommand { model.cancelFocusCompletion() }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(pending.completeTask ? "COMPLETE TASK · HOW DID THAT GO?" : "LOG PROGRESS · HOW DID THAT GO?")
        .font(.caption.weight(.bold))
        .foregroundStyle(.secondary)
      Text(pending.title)
        .font(.title3.weight(.semibold))
        .lineLimit(2)
        .truncationMode(.tail)
        .help(pending.title)
      Text("\(FocusPoints.formatted(pending.minutes)) minutes of focused work")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  private var qualityChoices: some View {
    VStack(spacing: 6) {
      ForEach(Array(FocusQuality.allCases.enumerated()), id: \.element) { index, option in
        Button {
          quality = option
          isCustom = false
        } label: {
          HStack(spacing: 10) {
            Text("\(index + 1)")
              .font(.caption.monospacedDigit().weight(.bold))
              .foregroundStyle(.secondary)
              .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
              Text(option.title).font(.body.weight(.medium))
              Text(option.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("×\(FocusPoints.formatted(option.multiplier))")
              .font(.callout.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 6)
          .padding(.horizontal, 10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
          .background(
            !isCustom && quality == option ? Color.accentColor.opacity(0.16) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .focusable()
        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
        .accessibilityLabel("\(option.title), \(option.detail)")
      }
    }
  }

  private var customRow: some View {
    HStack(spacing: 10) {
      Toggle("Something else", isOn: $isCustom)
        .toggleStyle(.switch)
        .focusable()
      Stepper(
        value: $customMultiplier,
        in: FocusPoints.multiplierRange,
        step: 0.25
      ) {
        Text("×\(FocusPoints.formatted(customMultiplier))")
          .font(.callout.monospacedDigit())
      }
      .focusable()
      .disabled(!isCustom)
      Spacer()
    }
    .onChange(of: customMultiplier) { _, _ in isCustom = true }
  }

  private var tally: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text("THIS BLOCK").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
        Text("\(FocusPoints.formatted(points)) pts")
          .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
          .foregroundStyle(Color.accentColor)
          .contentTransition(.numericText())
          .animation(.snappy, value: points)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 2) {
        Text("TODAY").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
        Text("\(FocusPoints.formatted(model.focusPoints.today + points)) pts")
          .font(.title3.monospacedDigit())
      }
    }
  }

  private var actions: some View {
    HStack {
      Text("1–5 choose · ↩ log it · esc keep working")
        .font(.caption)
        .foregroundStyle(.tertiary)
      Spacer()
      Button("Keep working") { model.cancelFocusCompletion() }
        .buttonStyle(.bordered)
        .focusable()
        .keyboardShortcut(.cancelAction)
      Button("Log it") { model.confirmFocusCompletion(multiplier: multiplier) }
        .buttonStyle(.borderedProminent)
        .focusable()
        .keyboardShortcut(.defaultAction)
    }
  }
}
