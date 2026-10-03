import PriorityWorkspace
import SwiftUI

/// A one-pixel rule in the border colour. Borders do the work shadows would.
struct Hairline: View {
  var color: Color = Palette.border
  var body: some View {
    Rectangle().fill(color).frame(height: Metrics.hairline)
  }
}

/// A sentence-case, muted label above a group — Zed's, not the old shouted
/// micro-label.
struct SectionLabel: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text)
      .font(Typeface.caption)
      .foregroundStyle(Palette.muted)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A small squarish tag: tinted fill, hairline of the same hue, text in it.
/// Status is never a solid block and never a capsule.
struct Tag: View {
  let text: String
  var tint: Color = Palette.muted
  var systemImage: String?
  var mono = false

  var body: some View {
    HStack(spacing: 3) {
      if let systemImage { Image(systemName: systemImage).imageScale(.small) }
      Text(text).lineLimit(1)
    }
    .font(mono ? Typeface.numeral : Typeface.footnote)
    .foregroundStyle(tint)
    .padding(.horizontal, 5)
    .padding(.vertical, 1)
    .background(RoundedRectangle(cornerRadius: Metrics.controlRadius - 2).fill(tint.opacity(0.10)))
    .overlay(RoundedRectangle(cornerRadius: Metrics.controlRadius - 2).strokeBorder(tint.opacity(0.35), lineWidth: Metrics.hairline))
  }
}

/// The themed checkbox: a square at the control radius that fills with
/// emerald when done, with a struck line for invalidated work. Drawn rather
/// than a stock toggle so it follows the palette.
struct TaskCheckbox: View {
  let status: TaskStatus
  var isList = false
  var size: CGFloat = 20

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: isList ? size / 2 : 5, style: .continuous)
    ZStack {
      shape.fill(fill)
      shape.strokeBorder(stroke, lineWidth: 1.25)
      switch status {
      case .completed:
        Image(systemName: "checkmark").font(.system(size: size * 0.55, weight: .bold)).foregroundStyle(.white)
      case .cancelled:
        Image(systemName: "minus").font(.system(size: size * 0.55, weight: .bold)).foregroundStyle(Palette.muted)
      case .open:
        EmptyView()
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  private var fill: Color {
    switch status {
    case .completed: Palette.success
    case .cancelled: Palette.well
    case .open: Color.clear
    }
  }

  private var stroke: Color {
    switch status {
    case .completed: Palette.success
    case .cancelled: Palette.inputBorder
    case .open: Palette.inputBorder
    }
  }
}

/// A flat toggle: a hairline track that fills with primary when on. The
/// inspector's switches, in the theme rather than the system's green.
struct ThemedToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button {
      configuration.isOn.toggle()
    } label: {
      HStack {
        configuration.label
          .font(Typeface.body)
          .foregroundStyle(Palette.ink)
        Spacer(minLength: Metrics.sm)
        ZStack(alignment: configuration.isOn ? .trailing : .leading) {
          RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(configuration.isOn ? Palette.primary : Palette.well)
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(configuration.isOn ? Palette.primary : Palette.inputBorder, lineWidth: Metrics.hairline))
            .frame(width: 40, height: 22)
          Circle().fill(Palette.raised).frame(width: 16, height: 16).padding(3)
            .overlay(Circle().strokeBorder(Palette.inputBorder, lineWidth: Metrics.hairline).padding(3))
        }
        .animation(.snappy(duration: 0.18), value: configuration.isOn)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityValue(configuration.isOn ? "On" : "Off")
    .accessibilityAddTraits(.isToggle)
  }
}

/// The frame every themed control sits in: a hairline at the control radius
/// on the raised surface.
struct ControlFrame: ViewModifier {
  var expands = true
  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
    content
      .font(Typeface.body)
      .foregroundStyle(Palette.ink)
      .padding(.horizontal, Metrics.sm + 2)
      .padding(.vertical, Metrics.sm)
      .frame(maxWidth: expands ? .infinity : nil, alignment: .leading)
      .background(shape.fill(Palette.raised))
      .overlay(shape.strokeBorder(Palette.inputBorder, lineWidth: Metrics.hairline))
  }
}

extension View {
  func controlFrame(expands: Bool = true) -> some View { modifier(ControlFrame(expands: expands)) }

  /// A raised, bordered panel — the card the house style layers on paper.
  func cardSurface(selected: Bool = false) -> some View {
    let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
    return self
      .background(shape.fill(Palette.raised))
      .overlay(shape.strokeBorder(selected ? Palette.primary : Palette.border, lineWidth: selected ? 1.5 : Metrics.hairline))
  }

  /// Paper behind a whole screen, including under the safe areas.
  func paperBackground() -> some View {
    background(Palette.paper.ignoresSafeArea())
  }
}

/// A themed button: primary filled, or quiet bordered.
struct ThemedButtonStyle: ButtonStyle {
  enum Kind { case primary, quiet, danger }
  var kind: Kind = .quiet
  var compact = false

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
    configuration.label
      .font(compact ? Typeface.caption.weight(.medium) : Typeface.callout.weight(.medium))
      .foregroundStyle(foreground)
      .padding(.horizontal, compact ? Metrics.sm : Metrics.md)
      .padding(.vertical, compact ? 5 : Metrics.sm)
      .frame(minHeight: compact ? 30 : 38)
      .background(shape.fill(background))
      .overlay(shape.strokeBorder(border, lineWidth: Metrics.hairline))
      .opacity(configuration.isPressed ? 0.7 : 1)
      .contentShape(shape)
  }

  private var foreground: Color {
    switch kind {
    case .primary: .white
    case .quiet: Palette.ink
    case .danger: Palette.danger
    }
  }

  private var background: Color {
    switch kind {
    case .primary: Palette.primary
    case .quiet: Palette.raised
    case .danger: Palette.danger.opacity(0.08)
    }
  }

  private var border: Color {
    switch kind {
    case .primary: Palette.primary
    case .quiet: Palette.inputBorder
    case .danger: Palette.danger.opacity(0.4)
    }
  }
}

/// What an empty surface says instead of being blank.
struct EmptyState: View {
  let title: String
  var message: String?
  var systemImage: String = "tray"

  var body: some View {
    VStack(spacing: Metrics.sm) {
      Image(systemName: systemImage)
        .font(.system(size: 28, weight: .light))
        .foregroundStyle(Palette.dim)
      Text(title).font(Typeface.bodyMedium).foregroundStyle(Palette.ink)
      if let message {
        Text(message).font(Typeface.caption).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
      }
    }
    .padding(Metrics.xl)
    .frame(maxWidth: .infinity)
  }
}

/// Lays its children out left to right, wrapping onto a new line when the
/// width runs out — chips that read as a sentence ("Lab or Office").
struct FlowLayout: Layout {
  var spacing: CGFloat = Metrics.xs

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
    let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
    let width = rows.map(\.width).max() ?? 0
    return CGSize(width: proposal.width ?? width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for row in arrange(width: bounds.width, subviews: subviews) {
      var x = bounds.minX
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(
          at: CGPoint(x: x, y: y + (row.height - size.height) / 2), anchor: .topLeading, proposal: .unspecified)
        x += size.width + spacing
      }
      y += row.height + spacing
    }
  }

  private struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
    var rows: [Row] = []
    var current = Row()
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      if needed > width, !current.indices.isEmpty {
        rows.append(current)
        current = Row()
      }
      current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      current.height = max(current.height, size.height)
      current.indices.append(index)
    }
    if !current.indices.isEmpty { rows.append(current) }
    return rows
  }
}
