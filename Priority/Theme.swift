import AppKit
import PriorityCore
import SwiftUI

/// A `ThemeSpecification` resolved against one appearance, in the currency
/// SwiftUI spends: `Color`, `CGFloat`, `Font`.
///
/// Views only ever touch this. They never see a hex string, never see a
/// `ThemeColorValue`, and never ask which appearance is in force — resolving
/// that is this type's entire reason to exist, and doing it once here is what
/// makes "theme swap" and "light/dark flip" the same mechanism.
struct Theme: Equatable {
  let specification: ThemeSpecification
  let appearance: ThemeAppearance

  // MARK: - Colour

  func color(_ role: ThemeColorRole) -> Color {
    Self.color(specification.color(role, in: appearance))
  }

  /// A role at reduced alpha, for the tinted fills the status convention is
  /// made of. The hue is the role's own — status is a fill *plus* a border
  /// *plus* text of the same hue, never a solid block.
  func color(_ role: ThemeColorRole, opacity: Double) -> Color {
    color(role).opacity(opacity)
  }

  /// The tint behind a status chip. 0.10 in both appearances: the accents keep
  /// their hex across the flip, so the fill has to do the adapting.
  static let statusFillOpacity = 0.10
  /// The border of that chip.
  static let statusBorderOpacity = 0.40

  var paper: Color { color(.paper) }
  var raised: Color { color(.raised) }
  var altRow: Color { color(.altRow) }
  var hover: Color { color(.hover) }
  var well: Color { color(.well) }
  var border: Color { color(.border) }
  var borderMuted: Color { color(.borderMuted) }
  var inputBorder: Color { color(.inputBorder) }
  var ink: Color { color(.ink) }
  var muted: Color { color(.mutedText) }
  var dim: Color { color(.dimText) }
  var primary: Color { color(.primary) }
  var success: Color { color(.success) }
  var danger: Color { color(.danger) }
  var warning: Color { color(.warning) }
  var categoricalPurple: Color { color(.categoricalPurple) }
  var categoricalPink: Color { color(.categoricalPink) }
  var categoricalOrange: Color { color(.categoricalOrange) }
  /// Fixed black/white, whichever appearance is in force: the photo underneath
  /// isn't ours to theme.
  var mediaLetterbox: Color { color(.mediaLetterbox) }
  var mediaScrim: Color { color(.mediaScrim) }
  var mediaScrimInk: Color { color(.mediaScrimInk) }

  /// The selection fill. Primary at low alpha rather than a separate role, so
  /// a theme that changes its primary changes its selection with it.
  var selectionFill: Color { color(.primary, opacity: 0.16) }
  var focusRing: Color { primary }

  // MARK: - Structure

  var radius: ThemeRadiusScale { specification.structure.radius }
  var borders: ThemeBorderScale { specification.structure.border }
  var space: ThemeSpacingScale { specification.structure.spacing }
  var type: ThemeTypography { specification.structure.typography }

  var panelRadius: CGFloat { specification.structure.radius.panel }
  var controlRadius: CGFloat { specification.structure.radius.control }
  var pillRadius: CGFloat { specification.structure.radius.pill }
  var shellRadius: CGFloat { specification.structure.radius.shell }
  var hairline: CGFloat { specification.structure.border.hairline }
  var emphasisBorder: CGFloat { specification.structure.border.emphasis }
  var focusRingWidth: CGFloat { specification.structure.border.focusRing }

  // MARK: - Type

  func font(_ face: ThemeFontFace, size: CGFloat, weight: ThemeFontWeight = .regular) -> Font {
    Self.font(face, size: size, weight: weight)
  }

  func bodyFont(size: CGFloat? = nil, weight: ThemeFontWeight = .regular) -> Font {
    font(type.body, size: size ?? type.bodySize, weight: weight)
  }

  var scale: ThemeTypeScale { type.scale }

  /// Fonts by role. Prefer these to a size: a literal point size is a place a
  /// theme can't reach.
  var captionFont: Font { bodyFont(size: scale.caption) }
  var titleFont: Font { displayFont(size: scale.title, weight: .semibold) }
  func numeralFont(_ size: CGFloat, weight: ThemeFontWeight = .medium) -> Font {
    monoFont(size: size, weight: weight)
  }

  func displayFont(size: CGFloat, weight: ThemeFontWeight = .bold) -> Font {
    font(type.display, size: size, weight: weight)
  }

  func monoFont(size: CGFloat, weight: ThemeFontWeight = .regular) -> Font {
    font(type.mono, size: size, weight: weight)
  }

  /// The micro-label's font. The tracking and the uppercasing come with the
  /// `.microLabel()` modifier — use that rather than this, unless you are
  /// styling something that is not a `Text`.
  var microLabelFont: Font {
    let label = type.microLabel
    return font(type.body, size: label.size, weight: label.weight)
  }

  var microLabelTracking: CGFloat { type.microLabel.trackingPoints }
  var microLabelColor: Color { color(type.microLabel.role) }
  var microLabelIsUppercased: Bool { type.microLabel.isUppercased }

  // MARK: - Bridges

  static func color(_ value: ThemeColorValue) -> Color {
    Color(
      .sRGB,
      red: value.red,
      green: value.green,
      blue: value.blue,
      opacity: value.alpha
    )
  }

  static func font(_ face: ThemeFontFace, size: CGFloat, weight: ThemeFontWeight) -> Font {
    // A *request*: Priority ships no font files, so the named families are
    // tried against what is installed and the design is what you actually get
    // until somebody installs Arvo. See `docs/plugins.md`.
    if let installed = face.families.first(where: { NSFont(name: $0, size: size) != nil }) {
      return Font.custom(installed, fixedSize: size).weight(swiftUIWeight(weight))
    }
    return .system(
      size: size, weight: swiftUIWeight(weight), design: swiftUIDesign(face.design))
  }

  static func swiftUIWeight(_ weight: ThemeFontWeight) -> Font.Weight {
    switch weight {
    case .regular: return .regular
    case .medium: return .medium
    case .semibold: return .semibold
    case .bold: return .bold
    case .black: return .black
    }
  }

  static func swiftUIDesign(_ design: ThemeFontDesign) -> Font.Design {
    switch design {
    case .serif: return .serif
    case .sans: return .default
    case .monospaced: return .monospaced
    case .rounded: return .rounded
    }
  }
}

// MARK: - Environment

private struct ThemeEnvironmentKey: EnvironmentKey {
  /// The house style, in light. Only ever seen by a preview or a view that
  /// escaped `.themed(_:)`; every real surface is handed the user's choice.
  static let defaultValue = Theme(
    specification: BuiltInThemeSpecifications.chalk,
    appearance: .light
  )
}

extension EnvironmentValues {
  var theme: Theme {
    get { self[ThemeEnvironmentKey.self] }
    set { self[ThemeEnvironmentKey.self] = newValue }
  }
}

/// Resolves the active theme against the appearance actually in force and puts
/// the result in the environment.
///
/// `colorScheme` is read here rather than in each view because that is the
/// join: `ThemeManager` knows *which* theme, SwiftUI knows *which appearance*,
/// and neither knows both.
private struct ThemedModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  let manager: ThemeManager

  func body(content: Content) -> some View {
    let specification = manager.specification
    // A theme that exists in one appearance only wins over the system
    // setting, because choosing it by name is choosing that appearance.
    let appearance = specification.lockedAppearance
      ?? (colorScheme == .dark ? .dark : .light)
    return content.environment(
      \.theme,
      Theme(specification: specification, appearance: appearance)
    )
  }
}

private struct ThemedBodyFontModifier: ViewModifier {
  @Environment(\.theme) private var theme

  func body(content: Content) -> some View {
    content.font(theme.bodyFont())
  }
}

extension View {
  /// Apply at every root that hosts app content — the window, the menu-bar
  /// popover, the settings window. A surface below one of these reads
  /// `@Environment(\.theme)` and gets both halves for free.
  func themed(_ manager: ThemeManager) -> some View {
    modifier(ThemedModifier(manager: manager))
  }

  /// The theme's body face as the default for everything below. Apply
  /// *inside* `.themed(_:)`, which is what supplies the theme it reads.
  ///
  /// The roots used to set `Typography.interfaceFont` — the system sans — so
  /// any text without a font of its own (an outline title, a sidebar name, a
  /// settings row) came out in the one face the theme never names.
  func themedBodyFont() -> some View {
    modifier(ThemedBodyFontModifier())
  }

  /// The signature device: 10pt, bold, uppercase, 0.15em tracking, muted.
  ///
  /// A modifier rather than a copied `.font(.system(size: 10, weight: .bold))`
  /// so that hierarchy stays a property of the theme. Every eyebrow, column
  /// header, chip caption and tab label in a migrated surface goes through it.
  func microLabel(_ theme: Theme, color override: Color? = nil) -> some View {
    font(theme.microLabelFont)
      .tracking(theme.microLabelTracking)
      .textCase(theme.microLabelIsUppercased ? .uppercase : nil)
      .foregroundStyle(override ?? theme.microLabelColor)
  }

  /// A hairline-bordered surface at one of the four radii. Rule 1 and rule 4
  /// in one call: a border, never a shadow.
  func themedSurface(
    _ theme: Theme,
    fill: Color? = nil,
    radius: CGFloat? = nil,
    stroke: Color? = nil,
    width: CGFloat? = nil
  ) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius ?? theme.panelRadius, style: .continuous)
    return background(shape.fill(fill ?? theme.raised))
      .overlay(shape.strokeBorder(stroke ?? theme.border, lineWidth: width ?? theme.hairline))
  }
}
