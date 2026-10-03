import PriorityCore
import PriorityWorkspace
import SwiftUI

/// The one question asked at the end of a block: how did that go? The Mac's
/// `WorkspaceFocusQualityPrompt`.
///
/// Presented once, at the root, for whichever surface ended the block — the
/// Focus screen, a running day card, the timer running out — so Today and
/// Focus ask it the same way. A block is worth the minutes it took multiplied
/// by the answer, and the running total is shown while choosing, so the cost
/// of flattering yourself is visible at the moment you would do it. On a
/// hardware keyboard 1–5 choose, Return logs and Escape keeps working.
struct BlockQualityPrompt: View {
  @Environment(WorkspaceModel.self) private var model
  let pending: PendingBlockCompletion

  @State private var quality: FocusQuality = .solid
  @State private var customMultiplier: Double = FocusQuality.solid.multiplier
  @State private var isCustom = false
  @State private var today = StoreQuery(0.0)

  private var multiplier: Double {
    isCustom ? FocusPoints.clamped(multiplier: customMultiplier) : quality.multiplier
  }

  private var points: Double {
    FocusPoints.score(seconds: pending.seconds, multiplier: multiplier)
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: Metrics.lg) {
          header
          choices
          customRow
          Hairline()
          tally
          Button("Log the time without a score") { model.confirmBlockCompletion(multiplier: nil) }
            .font(Typeface.callout)
            .foregroundStyle(Palette.muted)
            .accessibilityIdentifier("quality.skip")
        }
        .padding(Metrics.lg)
      }
      .background(Palette.paper)
      .navigationTitle("How did that go?")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Keep working") { model.cancelBlockCompletion() }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("quality.keepWorking")
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Log it") { model.confirmBlockCompletion(multiplier: multiplier) }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("quality.logIt")
        }
      }
    }
    .presentationDetents([.medium, .large])
    .interactiveDismissDisabled()
    .task {
      await today.load(model.store) { store in try store.focusPointsSummary(now: .now).today }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: Metrics.xs) {
      Text(pending.completeTask ? "Complete task" : "Log progress, task stays open")
        .font(Typeface.caption)
        .foregroundStyle(Palette.muted)
      Text(pending.title)
        .font(Typeface.title)
        .foregroundStyle(Palette.ink)
        .lineLimit(2)
      Text("\(FocusPoints.formatted(Double(pending.seconds) / 60)) minutes of focused work")
        .font(Typeface.numeral)
        .foregroundStyle(Palette.muted)
    }
  }

  private var choices: some View {
    VStack(spacing: 0) {
      ForEach(Array(FocusQuality.allCases.enumerated()), id: \.element) { index, option in
        let isChosen = !isCustom && quality == option
        Button {
          quality = option
          isCustom = false
        } label: {
          HStack(spacing: Metrics.md) {
            KeyCap("\(index + 1)")
            VStack(alignment: .leading, spacing: 1) {
              Text(option.title).font(Typeface.body).foregroundStyle(Palette.ink)
              Text(option.detail).font(Typeface.footnote).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: Metrics.sm)
            Text("×\(FocusPoints.formatted(option.multiplier))")
              .font(Typeface.numeralBody)
              .foregroundStyle(isChosen ? Palette.primary : Palette.muted)
          }
          .padding(.vertical, Metrics.sm + 2)
          .padding(.horizontal, Metrics.md)
          .frame(minHeight: Metrics.minimumHitTarget)
          .background(isChosen ? Palette.primary.opacity(0.10) : Color.clear)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
        .accessibilityLabel("\(option.title), \(option.detail)")
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .accessibilityIdentifier("quality.\(option.rawValue)")
        if index < FocusQuality.allCases.count - 1 { Hairline(color: Palette.borderMuted) }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
    .cardSurface()
  }

  private var customRow: some View {
    VStack(alignment: .leading, spacing: Metrics.sm) {
      Toggle("Something else", isOn: $isCustom)
        .toggleStyle(ThemedToggleStyle())
        .accessibilityIdentifier("quality.customToggle")
      if isCustom {
        HStack(spacing: Metrics.md) {
          Text("×\(FocusPoints.formatted(customMultiplier))")
            .font(Typeface.numeralBody)
            .foregroundStyle(Palette.primary)
            .frame(minWidth: 56, alignment: .leading)
          Stepper("Multiplier", value: $customMultiplier, in: FocusPoints.multiplierRange, step: 0.25)
            .labelsHidden()
            .accessibilityIdentifier("quality.custom")
          Spacer(minLength: 0)
        }
      }
    }
  }

  private var tally: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: Metrics.xxs) {
        Text("This block").font(Typeface.caption).foregroundStyle(Palette.muted)
        Text("\(FocusPoints.formatted(points)) pts")
          .font(Typeface.mono(28, .medium, relativeTo: .title))
          .foregroundStyle(Palette.primary)
          .contentTransition(.numericText())
          .animation(.snappy, value: points)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: Metrics.xxs) {
        Text("Today").font(Typeface.caption).foregroundStyle(Palette.muted)
        Text("\(FocusPoints.formatted(today.value + points)) pts")
          .font(Typeface.numeralBody)
          .foregroundStyle(Palette.ink)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("quality.tally")
  }
}

/// A key drawn as a key: the hardware shortcut that picks a row, which on a
/// touch screen still numbers the choices.
struct KeyCap: View {
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(Typeface.numeral)
      .foregroundStyle(Palette.muted)
      .frame(minWidth: 22, minHeight: 22)
      .overlay(RoundedRectangle(cornerRadius: Metrics.controlRadius).strokeBorder(Palette.border, lineWidth: 1))
      .accessibilityHidden(true)
  }
}
