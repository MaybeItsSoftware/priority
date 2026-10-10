import AppKit
import TaktCore
import SwiftUI
import os

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
  /// How far a disabled control fades. One figure for every button, chip and
  /// toggle, so "can't be pressed" reads the same everywhere.
  static let disabledOpacity = 0.45

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
  var rowRadius: CGFloat { specification.structure.radius.row }
  var controlRadius: CGFloat { specification.structure.radius.control }
  var pillRadius: CGFloat { specification.structure.radius.pill }
  var shellRadius: CGFloat { specification.structure.radius.shell }
  var hairline: CGFloat { specification.structure.border.hairline }
  var emphasisBorder: CGFloat { specification.structure.border.emphasis }
  var focusRingWidth: CGFloat { specification.structure.border.focusRing }

  /// The height of every column's header band — the sidebar's, the main
  /// pane's and the right dock's tab bar — hairline included. One figure so
  /// the rule under the three of them is one line across the window rather
  /// than three that miss each other, the way an editor's panel headers line
  /// up with its tab bar. From the spacing scale, so a denser theme tightens
  /// the band with everything else.
  var paneHeaderHeight: CGFloat { CGFloat(space.xl + space.sm) }

  /// The main window's title strip, hairline included. The pane header
  /// band's height — 38pt on the default scale, which is Zed's title bar — so
  /// the bar the traffic lights sit in and the bands under it are one rhythm.
  var titleStripHeight: CGFloat { paneHeaderHeight }

  /// The square a header's or the status bar's icon button occupies: room for
  /// a caption-sized glyph and a hover fill round it, and no more.
  var paneIconButtonSize: CGFloat { CGFloat(space.lg + space.xs) }

  // MARK: - Rows
  //
  // Every list in the window — the sidebar, the outline, Today, the done rail,
  // the overlays' results — runs its rows edge to edge of its pane, the way an
  // editor's project panel does: the selection is a band the full width of the
  // column, and the gutter is laid *inside* the row, so the text still starts
  // where the header's title does. These are those gutters and that height.

  /// The main pane's side gutter: its header's title, and the text of every
  /// row beneath it — the outline, Today, the done rail's day headings. The
  /// full-pane surfaces (Focus, the timeline) are laid out on it too.
  var paneGutter: CGFloat { CGFloat(space.xl) }

  /// The narrower gutter of the sidebar and the overlays' result lists, where
  /// a column is a third the width and a pane's gutter would eat the names.
  var listGutter: CGFloat { CGFloat(space.md) }

  /// Above and below a single line of row text. With body text this makes a
  /// row about 25pt — one line and a little air, Zed's density rather than a
  /// source list's.
  var rowVerticalPadding: CGFloat { CGFloat(space.xs) }

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
  ///
  /// Weight is not how hierarchy is made here — surface, position and size
  /// are — so everything defaults to regular and a pane title reaches no
  /// further than medium. Heavier is kept for something that is *live*, such
  /// as the running timer, where it says "this is the one moving".
  var captionFont: Font { bodyFont(size: scale.caption) }
  /// Monospace at the micro-label's size: keycaps, counts and status readouts.
  var monoCaptionFont: Font { monoFont(size: type.microLabel.size) }
  var titleFont: Font { displayFont(size: scale.title, weight: .medium) }
  func numeralFont(_ size: CGFloat, weight: ThemeFontWeight = .regular) -> Font {
    monoFont(size: size, weight: weight)
  }

  func displayFont(size: CGFloat, weight: ThemeFontWeight = .medium) -> Font {
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
    // A *request*: the named families are tried against what is installed —
    // which includes the faces the app registers at launch, see
    // `BundledFonts` — and the design is what you get when none is.
    switch installedFont(face, weight: weight) {
    case .face(let postScriptName):
      return Font.custom(postScriptName, fixedSize: size)
    case .named(let name):
      return Font.custom(name, fixedSize: size).weight(swiftUIWeight(weight))
    case nil:
      return .system(
        size: size, weight: swiftUIWeight(weight), design: swiftUIDesign(face.design))
    }
  }

  /// The same resolution for a surface that has to be AppKit — a toolbar
  /// field, a table cell. One resolver, so the two halves cannot disagree
  /// about which face a theme gets.
  static func nsFont(_ face: ThemeFontFace, size: CGFloat, weight: ThemeFontWeight = .regular)
    -> NSFont
  {
    switch installedFont(face, weight: weight) {
    case .face(let postScriptName):
      if let font = NSFont(name: postScriptName, size: size) { return font }
    case .named(let name):
      if let font = NSFont(name: name, size: size) {
        let isBold = [.semibold, .bold, .black].contains(weight)
        return isBold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
      }
    case nil:
      break
    }
    let system = NSFont.systemFont(ofSize: size, weight: appKitWeight(weight))
    let design: NSFontDescriptor.SystemDesign
    switch face.design {
    case .serif: design = .serif
    case .monospaced: design = .monospaced
    case .rounded: design = .rounded
    case .sans: design = .default
    }
    return system.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) }
      ?? system
  }

  /// What a face request resolved to.
  enum InstalledFont: Equatable {
    /// A family was found and has a real face at this weight, named exactly —
    /// so medium is the file drawn as medium, not regular made heavier.
    case face(postScriptName: String)
    /// A single font by PostScript or full name, which is how some families
    /// can only be reached. The weight is applied to it as a trait.
    case named(String)
  }

  /// Looked up per family and weight, not per size: the answer is the same
  /// at every size, and views ask on every redraw.
  private static let resolved = OSAllocatedUnfairLock<[String: InstalledFont?]>(initialState: [:])

  static func installedFont(_ face: ThemeFontFace, weight: ThemeFontWeight) -> InstalledFont? {
    let key = face.families.joined(separator: "\u{1F}") + "|" + weight.rawValue
    if let cached = resolved.withLock({ $0[key] }) { return cached }
    let answer = lookUp(face.families, weight: weight)
    resolved.withLock { $0[key] = .some(answer) }
    return answer
  }

  private static func lookUp(_ families: [String], weight: ThemeFontWeight) -> InstalledFont? {
    let manager = NSFontManager.shared
    for family in families {
      if manager.availableMembers(ofFontFamily: family) != nil,
        let font = manager.font(
          withFamily: family, traits: [], weight: appKitManagerWeight(weight), size: 12) {
        return .face(postScriptName: font.fontName)
      }
      if NSFont(name: family, size: 12) != nil { return .named(family) }
    }
    return nil
  }

  /// `NSFontManager`'s 0–15 weight scale: 5 is regular, 9 bold. It picks the
  /// nearest face the family has, so Lilex, which has no semibold, gives bold.
  static func appKitManagerWeight(_ weight: ThemeFontWeight) -> Int {
    switch weight {
    case .regular: return 5
    case .medium: return 6
    case .semibold: return 8
    case .bold: return 9
    case .black: return 11
    }
  }

  static func appKitWeight(_ weight: ThemeFontWeight) -> NSFont.Weight {
    switch weight {
    case .regular: return .regular
    case .medium: return .medium
    case .semibold: return .semibold
    case .bold: return .bold
    case .black: return .black
    }
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
  /// The default theme, in light. Only ever seen by a preview or a view that
  /// escaped `.themed(_:)`; every real surface is handed the user's choice.
  static let defaultValue = Theme(
    specification: BuiltInThemeSpecifications.priority,
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

  /// The quiet label on section headers, column heads and chip captions:
  /// caption-sized, regular, as written, muted — the way Zed labels a panel.
  /// Case, tracking and weight are all theme tokens, so a theme can bring back
  /// the old 10pt bold tracked capitals without touching a view.
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
