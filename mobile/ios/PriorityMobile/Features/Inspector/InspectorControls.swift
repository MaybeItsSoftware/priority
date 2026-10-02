import SwiftUI

/// A row of squarish chips, one of which is chosen — the Mac's
/// `ThemedSegmentedPicker`, at touch size. Selection is a border and a tint,
/// never elevation.
struct ChoiceChips<Value: Hashable>: View {
  let options: [(title: String, value: Value)]
  @Binding var selection: Value
  var tint: Color = Palette.primary
  var identifier: String?

  var body: some View {
    HStack(spacing: Metrics.xs) {
      ForEach(Array(options.enumerated()), id: \.offset) { index, option in
        let selected = option.value == selection
        Button {
          selection = option.value
        } label: {
          Text(option.title)
            .font(Typeface.callout)
            .foregroundStyle(selected ? tint : Palette.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(
              RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                .fill(selected ? tint.opacity(0.10) : Palette.raised))
            .overlay(
              RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                .strokeBorder(selected ? tint.opacity(0.6) : Palette.inputBorder, lineWidth: selected ? 1 : Metrics.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier.map { "\($0).\(index)" } ?? "")
      }
    }
    .frame(minHeight: Metrics.minimumHitTarget)
  }
}

/// A labelled row: the muted label on the left, the control on the right.
struct InspectorRow<Content: View>: View {
  let label: String
  @ViewBuilder var content: Content

  init(_ label: String, @ViewBuilder content: () -> Content) {
    self.label = label
    self.content = content()
  }

  var body: some View {
    HStack(alignment: .center, spacing: Metrics.md) {
      Text(label)
        .font(Typeface.callout)
        .foregroundStyle(Palette.muted)
        .frame(width: 92, alignment: .leading)
      content
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minHeight: Metrics.minimumHitTarget)
  }
}

/// A group of rows under a sentence-case label, closed by a hairline.
struct InspectorSection<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Metrics.sm) {
      SectionLabel(title)
      content
    }
    .padding(.horizontal, Metrics.lg)
    .padding(.vertical, Metrics.md)
    .overlay(alignment: .bottom) { Hairline(color: Palette.borderMuted) }
  }
}

/// A menu drawn as a themed control rather than a stock pop-up button.
struct ThemedMenuLabel: View {
  let title: String
  var systemImage: String = "chevron.up.chevron.down"

  var body: some View {
    HStack {
      Text(title).lineLimit(1)
      Spacer(minLength: Metrics.xs)
      Image(systemName: systemImage).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
    }
    .controlFrame()
    .contentShape(Rectangle())
  }
}
