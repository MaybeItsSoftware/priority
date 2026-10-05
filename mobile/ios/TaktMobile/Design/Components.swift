import TaktCore
import TaktWorkspace
import SwiftUI

/// A one-pixel rule in the border colour. Borders do the work shadows would.
struct Hairline: View {
  @Environment(\.theme) private var theme
  var role: ThemeColorRole = .border
  var body: some View {
    Rectangle().fill(theme.color(role)).frame(height: theme.hairline)
  }
}

/// The theme's micro-label above a group. Chalk sets it sentence-case and
/// muted, the way Zed does; a theme can bring back the shouted capitals.
struct SectionLabel: View {
  @Environment(\.theme) private var theme
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text)
      .microLabel()
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

extension View {
  /// Sets text as the theme's micro-label: its size, weight, tracking, case
  /// and colour role.
  func microLabel() -> some View { modifier(MicroLabelModifier()) }
}

private struct MicroLabelModifier: ViewModifier {
  @Environment(\.theme) private var theme

  func body(content: Content) -> some View {
    let label = theme.type.microLabel
    content
      .font(label.font)
      .tracking(label.tracking)
      .textCase(label.isUppercased ? .uppercase : nil)
      .foregroundStyle(theme.color(label.role))
  }
}

/// A small squarish tag: tinted fill, hairline of the same hue, text in it.
/// Status is never a solid block and never a capsule.
struct Tag: View {
  @Environment(\.theme) private var theme
  let text: String
  var tint: Color?
  var systemImage: String?
  var mono = false

  var body: some View {
    HStack(spacing: 3) {
      if let systemImage { Image(systemName: systemImage).imageScale(.small) }
      Text(text).lineLimit(1)
    }
    .font(mono ? theme.type.numeral : theme.type.footnote)
    .foregroundStyle(hue)
    .padding(.horizontal, 5)
    .padding(.vertical, 1)
    .background(RoundedRectangle(cornerRadius: theme.radius.tag).fill(hue.opacity(0.10)))
    .overlay(RoundedRectangle(cornerRadius: theme.radius.tag).strokeBorder(hue.opacity(0.35), lineWidth: theme.hairline))
  }

  private var hue: Color { tint ?? theme.muted }
}

/// The themed checkbox: a square at the control radius that fills with
/// emerald when done, with a struck line for invalidated work. Drawn rather
/// than a stock toggle so it follows the palette.
struct TaskCheckbox: View {
  @Environment(\.theme) private var theme
  let status: TaskStatus
  var isList = false
  var size: CGFloat = 20

  var body: some View {
    let shape = RoundedRectangle(
      cornerRadius: isList ? min(size / 2, theme.radius.pill) : max(0, theme.radius.control - 1), style: .continuous)
    ZStack {
      shape.fill(fill)
      shape.strokeBorder(stroke, lineWidth: 1.25)
      switch status {
      case .completed:
        Image(systemName: "checkmark").font(.system(size: size * 0.55, weight: .bold)).foregroundStyle(theme.onAccent)
      case .cancelled:
        Image(systemName: "minus").font(.system(size: size * 0.55, weight: .bold)).foregroundStyle(theme.muted)
      case .open:
        EmptyView()
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  private var fill: Color {
    switch status {
    case .completed: theme.success
    case .cancelled: theme.well
    case .open: Color.clear
    }
  }

  private var stroke: Color {
    switch status {
    case .completed: theme.success
    case .cancelled: theme.inputBorder
    case .open: theme.inputBorder
    }
  }
}

/// A flat toggle: a hairline track that fills with primary when on. The
/// inspector's switches, in the theme rather than the system's green.
struct ThemedToggleStyle: ToggleStyle {
  @Environment(\.theme) private var theme
  func makeBody(configuration: Configuration) -> some View {
    Button {
      configuration.isOn.toggle()
    } label: {
      HStack {
        configuration.label
          .font(theme.type.body)
          .foregroundStyle(theme.ink)
        Spacer(minLength: theme.space.sm)
        ZStack(alignment: configuration.isOn ? .trailing : .leading) {
          RoundedRectangle(cornerRadius: min(11, theme.radius.pill), style: .continuous)
            .fill(configuration.isOn ? theme.primary : theme.well)
            .overlay(RoundedRectangle(cornerRadius: min(11, theme.radius.pill)).strokeBorder(configuration.isOn ? theme.primary : theme.inputBorder, lineWidth: theme.hairline))
            .frame(width: 40, height: 22)
          Circle().fill(theme.raised).frame(width: 16, height: 16).padding(3)
            .overlay(Circle().strokeBorder(theme.inputBorder, lineWidth: theme.hairline).padding(3))
        }
        .animation(.snappy(duration: 0.18), value: configuration.isOn)
      }
      .contentShape(HitArea(minimum: theme.touchTarget))
    }
    .buttonStyle(.plain)
    .accessibilityValue(configuration.isOn ? "On" : "Off")
    .accessibilityAddTraits(.isToggle)
  }
}

/// The frame every themed control sits in: a hairline at the control radius
/// on the raised surface.
struct ControlFrame: ViewModifier {
  @Environment(\.theme) private var theme
  var expands = true
  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: theme.radius.control, style: .continuous)
    content
      .font(theme.type.body)
      .foregroundStyle(theme.ink)
      .padding(.horizontal, theme.space.sm + 2)
      .padding(.vertical, theme.space.sm)
      .frame(maxWidth: expands ? .infinity : nil, alignment: .leading)
      .background(shape.fill(theme.raised))
      .overlay(shape.strokeBorder(theme.inputBorder, lineWidth: theme.hairline))
  }
}

extension View {
  func controlFrame(expands: Bool = true) -> some View { modifier(ControlFrame(expands: expands)) }

  /// A raised, bordered panel — the card the house style layers on paper.
  func cardSurface(selected: Bool = false) -> some View { modifier(CardSurface(selected: selected)) }

  /// Paper behind a whole screen, including under the safe areas.
  func paperBackground() -> some View { modifier(PaperBackground()) }
}

private struct CardSurface: ViewModifier {
  @Environment(\.theme) private var theme
  let selected: Bool

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: theme.radius.panel, style: .continuous)
    content
      .background(shape.fill(theme.raised))
      .overlay(
        shape.strokeBorder(
          selected ? theme.primary : theme.border, lineWidth: selected ? theme.emphasis * 0.75 : theme.hairline))
  }
}

private struct PaperBackground: ViewModifier {
  @Environment(\.theme) private var theme

  func body(content: Content) -> some View {
    content.background(theme.paper.ignoresSafeArea())
  }
}

/// A themed button: primary filled, or quiet bordered.
struct ThemedButtonStyle: ButtonStyle {
  @Environment(\.theme) private var theme
  enum Kind { case primary, quiet, danger }
  var kind: Kind = .quiet
  var compact = false

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: theme.radius.control, style: .continuous)
    configuration.label
      .font(compact ? theme.type.caption.weight(.medium) : theme.type.callout.weight(.medium))
      .foregroundStyle(foreground)
      .padding(.horizontal, compact ? theme.space.sm : theme.space.md)
      .padding(.vertical, compact ? 5 : theme.space.sm)
      .frame(minHeight: compact ? 30 : 38)
      .background(shape.fill(background))
      .overlay(shape.strokeBorder(border, lineWidth: theme.hairline))
      .opacity(configuration.isPressed ? 0.7 : 1)
      .contentShape(HitArea(minimum: theme.touchTarget))
  }

  private var foreground: Color {
    switch kind {
    case .primary: theme.onAccent
    case .quiet: theme.ink
    case .danger: theme.danger
    }
  }

  private var background: Color {
    switch kind {
    case .primary: theme.primary
    case .quiet: theme.raised
    case .danger: theme.danger.opacity(0.08)
    }
  }

  private var border: Color {
    switch kind {
    case .primary: theme.primary
    case .quiet: theme.inputBorder
    case .danger: theme.danger.opacity(0.4)
    }
  }
}

/// What an empty surface says instead of being blank.
struct EmptyState: View {
  @Environment(\.theme) private var theme
  let title: String
  var message: String?
  var systemImage: String = "tray"

  var body: some View {
    VStack(spacing: theme.space.sm) {
      Image(systemName: systemImage)
        .font(theme.type.glyph(28, .light))
        .foregroundStyle(theme.dim)
      Text(title).font(theme.type.bodyMedium).foregroundStyle(theme.ink)
      if let message {
        Text(message).font(theme.type.caption).foregroundStyle(theme.muted).multilineTextAlignment(.center)
      }
    }
    .padding(theme.space.xl)
    .frame(maxWidth: .infinity)
  }
}

/// Lays its children out left to right, wrapping onto a new line when the
/// width runs out — chips that read as a sentence ("Lab or Office").
struct FlowLayout: Layout {
  var spacing: CGFloat = 4

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
