import PriorityCore
import SwiftUI

/// The small shared vocabulary every focus surface is built from — the pane,
/// the summoned panel, and the context bar.
///
/// It exists so the three of them cannot drift. Before this, each surface set
/// its own caption size, tracking and key-cap padding inline, and they had
/// already diverged by a point here and a corner radius there.

/// The quiet label: in the built-ins, caption-sized, regular, as written and
/// muted, the way Zed labels a panel. Section eyebrows, column headers and chip
/// captions all use it, so hierarchy reads from surface and position rather
/// than from label size. Write the text in sentence case — it is shown as
/// given unless a theme asks for capitals.
struct MicroLabel: View {
  @Environment(\.theme) private var theme
  let text: String
  var tint: Color?

  init(_ text: String, tint: Color? = nil) {
    self.text = text
    self.tint = tint
  }

  // The size, weight, tracking and case are the theme's, not this view's.
  // They were written out here as 10/bold/1.5/uppercase, which is the house
  // figure — but a figure copied into a view is a figure a theme cannot
  // change, and the point of the micro-label is that it is one decision.
  var body: some View {
    Text(text)
      .microLabel(theme, color: tint)
  }
}

/// A key drawn as a key. Every action that has a shortcut shows it here rather
/// than in a reference sheet, because a shortcut you have to go and look up is
/// a shortcut nobody learns.
struct KeyCap: View {
  @Environment(\.theme) private var theme
  let key: String

  init(_ key: String) { self.key = key }

  // A control-radius chip in the monospaced face, bordered rather than
  // filled — rule 1, and the one radius scale. Set at the micro-label's size
  // so a key reads as belonging to the label beside it.
  var body: some View {
    Text(key)
      .font(theme.monoFont(size: theme.type.microLabel.size))
      .foregroundStyle(theme.muted)
      .padding(.horizontal, theme.space.xs)
      .padding(.vertical, theme.space.xxs)
      .overlay(
        RoundedRectangle(cornerRadius: theme.controlRadius)
          .strokeBorder(theme.border, lineWidth: theme.hairline))
  }
}

/// `key` then `label`, for the hint rows along the foot of a focus surface.
struct KeyHint: View {
  @Environment(\.theme) private var theme
  let key: String
  let label: String

  init(_ key: String, _ label: String) {
    self.key = key
    self.label = label
  }

  var body: some View {
    HStack(spacing: theme.space.xs) {
      KeyCap(key)
      Text(label)
        .font(theme.captionFont)
        .foregroundStyle(theme.dim)
    }
  }
}

/// The hairline that separates one band of a focus surface from the next.
/// Separation is a 1px rule here, never a shadow and never a nested card.
struct FocusRule: View {
  @Environment(\.theme) private var theme

  var body: some View {
    Rectangle()
      .fill(theme.border)
      .frame(height: theme.hairline)
  }
}

/// The band geometry every full-pane surface is laid out on.
///
/// Focus and the timeline are the same kind of thing — a surface that takes the
/// whole pane, with a titled band across the top and a hint band across the
/// bottom — and they were built to different figures. Focus used a 24pt gutter
/// and 12pt bands; the timeline used 20pt and 12/14/10, so switching between
/// them with ⌘8 and ⌘9 shifted every edge on screen and made the two read as
/// unrelated screens rather than two views of the same day.
///
/// The modifiers below read these from the theme's spacing scale — the gutter
/// is `space.xl`, a band `space.md` — so a denser theme tightens every
/// full-pane surface at once. The constants remain for the few places that
/// need a number outside a view modifier, and match the house theme.
enum FocusSurfaceMetrics {
  /// The side gutter, shared by the bands and the content between them.
  static let gutter: CGFloat = 24
  /// The height contribution of the top and bottom bands. One figure: a header
  /// taller than its footer makes a pane look like it is sliding upwards.
  static let band: CGFloat = 12
  /// The gutter for a notice strip inset inside a band — narrower on purpose,
  /// so it reads as sitting within the surface rather than as another band.
  static let noticeGutter: CGFloat = 12
}

private struct FocusSurfacePadding: ViewModifier {
  @Environment(\.theme) private var theme
  let includesBand: Bool

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, theme.paneGutter)
      .padding(.vertical, includesBand ? theme.space.md : 0)
  }
}

extension View {
  /// A band across the top or bottom of a full-pane surface.
  func focusSurfaceBand() -> some View {
    modifier(FocusSurfacePadding(includesBand: true))
  }

  /// The side gutter on its own, for the content between the bands.
  func focusSurfaceGutter() -> some View {
    modifier(FocusSurfacePadding(includesBand: false))
  }
}

/// The one button a focus surface draws, in two weights.
///
/// Flat and bordered, at the control radius: the system's bordered styles
/// paint in the accent colour and a bezel of their own, neither of which a
/// theme can reach. The prominent weight is the status convention in primary —
/// a tinted fill, a border and text of the same hue — so the one action a
/// screen wants you to take is marked by colour and not by elevation.
struct FocusActionButtonStyle: ButtonStyle {
  var prominent = false
  /// Larger padding for the few actions that are the point of their screen.
  var large = false

  func makeBody(configuration: Configuration) -> some View {
    FocusActionButtonBody(configuration: configuration, prominent: prominent, large: large)
  }
}

/// A view rather than the style's own body, so the hover state has somewhere
/// to live.
private struct FocusActionButtonBody: View {
  @Environment(\.theme) private var theme
  @Environment(\.isEnabled) private var isEnabled
  let configuration: ButtonStyleConfiguration
  let prominent: Bool
  let large: Bool
  @State private var isHovering = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
    let pressed = configuration.isPressed
    return configuration.label
      .font(theme.bodyFont(weight: prominent ? .semibold : .medium))
      .foregroundStyle(
        configuration.role == .destructive ? theme.danger : (prominent ? theme.primary : theme.ink))
      .padding(.horizontal, large ? theme.space.md : theme.space.sm)
      .padding(.vertical, large ? theme.space.sm : theme.space.xs)
      .background(shape.fill(fill(pressed: pressed)))
      .overlay(
        shape.strokeBorder(
          prominent ? theme.primary.opacity(Theme.statusBorderOpacity) : theme.border,
          lineWidth: theme.hairline))
      .opacity(isEnabled ? 1 : 0.45)
      .contentShape(shape)
      .onHover { isHovering = $0 }
  }

  private func fill(pressed: Bool) -> Color {
    if prominent {
      return theme.primary.opacity(pressed ? 0.24 : (isHovering ? 0.16 : Theme.statusFillOpacity))
    }
    if pressed { return theme.well }
    return isHovering ? theme.hover : Color.clear
  }
}

/// A chip that is either on or off: a condition that holds, an estimate that
/// is chosen. Bordered and squarish, never a capsule; on is the primary status
/// tint, off is a hairline and muted text.
struct FocusChipButtonStyle: ButtonStyle {
  let isOn: Bool

  func makeBody(configuration: Configuration) -> some View {
    FocusChipButtonBody(configuration: configuration, isOn: isOn)
  }
}

private struct FocusChipButtonBody: View {
  @Environment(\.theme) private var theme
  let configuration: ButtonStyleConfiguration
  let isOn: Bool

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
    return configuration.label
      .font(theme.captionFont)
      .monospacedDigit()
      .foregroundStyle(isOn ? theme.primary : theme.muted)
      .padding(.horizontal, theme.space.sm)
      .padding(.vertical, theme.space.xxs)
      .background(
        shape.fill(
          isOn
            ? theme.primary.opacity(Theme.statusFillOpacity)
            : (configuration.isPressed ? theme.well : Color.clear)))
      .overlay(
        shape.strokeBorder(
          isOn ? theme.primary.opacity(Theme.statusBorderOpacity) : theme.border,
          lineWidth: theme.hairline))
      .contentShape(shape)
  }
}
