import PriorityCore
import SwiftUI
import UIKit

/// The theme every view draws through, read as `@Environment(\.theme)`.
///
/// A projection of a `ThemeSpecification` resolved for the iPhone: colour
/// roles as dynamic colours (they flip with the trait collection, so light and
/// dark need no redraw of their own), the structure's radii, rules, spacing and
/// type, and the minimum hit target. `ThemeStore` builds a new one whenever
/// the chosen theme changes, and the environment carries it to every view, so
/// a change of theme redraws live.
struct Theme {
  let specification: ThemeSpecification
  let structure: ThemeStructure
  let touchTarget: CGFloat
  let radius: Radii
  let space: Spacing
  let type: TypeSet
  /// The default rule. A theme's hairline is in pixels, the way the house
  /// style states it ("1px borders"), so 1 is one device pixel.
  let hairline: CGFloat
  /// The same rule in points, for an outline that has to read at a glance —
  /// a card, a drop target, a stepper's frame.
  let stroke: CGFloat
  /// A selected or active edge.
  let emphasis: CGFloat
  /// The focus ring, drawn in `primary`.
  let focusRing: CGFloat

  private let colors: [ThemeColorRole: Color]
  private let uiColors: [ThemeColorRole: UIColor]

  init(specification: ThemeSpecification, platform resolved: PlatformStructure.Resolved, displayScale: CGFloat) {
    self.specification = specification
    self.structure = resolved.structure
    self.touchTarget = resolved.touchTarget
    let structure = resolved.structure
    radius = Radii(
      panel: structure.radius.panel, row: structure.radius.row, control: structure.radius.control,
      pill: structure.radius.pill)
    space = Spacing(structure.spacing)
    type = TypeSet(structure.typography)
    let scale = max(1, displayScale)
    hairline = structure.border.hairline / scale
    stroke = structure.border.hairline
    emphasis = structure.border.emphasis
    focusRing = structure.border.focusRing
    var uiColors: [ThemeColorRole: UIColor] = [:]
    for role in ThemeColorRole.allCases {
      uiColors[role] = Self.dynamic(role, of: specification)
    }
    self.uiColors = uiColors
    colors = uiColors.mapValues { Color(uiColor: $0) }
  }

  /// Chalk, as the iPhone draws it: what the environment holds before a store
  /// has said otherwise, and what previews and tests see.
  static let chalk = Theme(
    specification: BuiltInThemeSpecifications.chalk,
    platform: PlatformStructure.resolve(BuiltInThemeSpecifications.chalk), displayScale: 3)

  /// The appearance this theme insists on, if it is a one-appearance theme
  /// such as Chalk Dark.
  var lockedColorScheme: ColorScheme? {
    switch specification.lockedAppearance {
    case .light: .light
    case .dark: .dark
    case nil: nil
    }
  }

  func color(_ role: ThemeColorRole) -> Color { colors[role] ?? .clear }
  func uiColor(_ role: ThemeColorRole) -> UIColor { uiColors[role] ?? .clear }

  // MARK: Roles

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
  var purple: Color { color(.categoricalPurple) }
  var pink: Color { color(.categoricalPink) }
  var orange: Color { color(.categoricalOrange) }
  /// Text and glyphs set on a filled accent (a primary button, a done
  /// checkbox). Theme-invariant, like the media roles it is read from.
  var onAccent: Color { color(.mediaScrimInk) }

  private static func dynamic(_ role: ThemeColorRole, of specification: ThemeSpecification) -> UIColor {
    // Media roles are read from the light table whatever is in force.
    let invariant = ThemeColorRole.themeInvariant.contains(role)
    let light = specification.palette.color(role, in: .light)
    let dark = invariant ? light : specification.palette.color(role, in: .dark)
    return UIColor { traits in
      let value = traits.userInterfaceStyle == .dark ? dark : light
      return UIColor(red: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
    }
  }

  // MARK: Structure

  struct Radii: Equatable {
    /// Cards, panels, popovers and sheets' inner panels.
    let panel: CGFloat
    /// A list row's selection and hover.
    let row: CGFloat
    /// Buttons, inputs, chips, tooltips.
    let control: CGFloat
    /// Genuinely round things.
    let pill: CGFloat

    /// A tag or badge set inside a control: a step tighter than the control.
    var tag: CGFloat { max(0, control - 2) }
  }

  struct Spacing: Equatable {
    let xxs: CGFloat
    let xs: CGFloat
    let sm: CGFloat
    let md: CGFloat
    let lg: CGFloat
    let xl: CGFloat

    init(_ scale: ThemeSpacingScale) {
      xxs = scale.xxs
      xs = scale.xs
      sm = scale.sm
      md = scale.md
      lg = scale.lg
      xl = scale.xl
    }
  }
}

extension Theme: Equatable {
  static func == (lhs: Theme, rhs: Theme) -> Bool {
    lhs.specification == rhs.specification && lhs.structure == rhs.structure
      && lhs.touchTarget == rhs.touchTarget && lhs.hairline == rhs.hairline
  }
}

// MARK: - Type

extension Theme {
  /// The theme's faces and its type scale, as the fonts views ask for by role.
  ///
  /// The named fonts are the iPhone's interface roles, each taken from the
  /// theme's scale: `body`, `caption`, `title`, `display` and `hero` are the
  /// scale itself; `callout` and `footnote` sit a step either side. Every font
  /// is relative to a Dynamic Type text style, so the interface still follows
  /// the user's text size. `sans(_:)`, `mono(_:)` and `glyph(_:)` are for the
  /// few sizes that belong to one layout: they are stated against Chalk's
  /// 17pt body and scale with the theme's.
  struct TypeSet: Equatable {
    let body: Font
    let bodyMedium: Font
    let callout: Font
    let caption: Font
    let footnote: Font
    let title: Font
    let largeTitle: Font
    let numeral: Font
    let numeralBody: Font
    let display: Font
    let hero: Font
    let microLabel: MicroLabel
    let scale: ThemeTypeScale

    private let bodyFace: ResolvedFace
    private let displayFace: ResolvedFace
    private let monoFace: ResolvedFace
    /// The theme's body size against Chalk's on the iPhone.
    private let factor: CGFloat

    /// The iPhone's body size in Chalk, which layout-specific sizes are
    /// stated against.
    static let referenceBody: CGFloat = 17

    init(_ typography: ThemeTypography) {
      let scale = typography.scale
      self.scale = scale
      bodyFace = ResolvedFace(typography.body)
      displayFace = ResolvedFace(typography.display)
      monoFace = ResolvedFace(typography.mono)
      factor = max(0.5, scale.body / Self.referenceBody)
      let callout = (scale.body - 1).rounded()
      body = bodyFace.font(scale.body, .regular, .body)
      bodyMedium = bodyFace.font(scale.body, .medium, .body)
      self.callout = bodyFace.font(callout, .regular, .callout)
      caption = bodyFace.font(scale.caption, .regular, .caption)
      footnote = bodyFace.font(scale.caption - 1, .regular, .footnote)
      // The phone sets its pane headings, big numbers and the focus timer a
      // step under the scale's title, display and hero, as it always has;
      // stating them as proportions keeps them following a theme's scale.
      title = displayFace.font((scale.title * 0.85).rounded(), .semibold, .headline)
      largeTitle = displayFace.font((scale.display * 0.82).rounded(), .semibold, .largeTitle)
      numeral = monoFace.font(scale.caption, .regular, .caption)
      numeralBody = monoFace.font(callout, .regular, .body)
      display = monoFace.font(scale.display, .medium, .largeTitle)
      hero = monoFace.font((scale.hero * 0.78).rounded(), .medium, .largeTitle)
      microLabel = MicroLabel(typography.microLabel, face: bodyFace)
    }

    /// The body face at a size stated against Chalk's 17pt body.
    func sans(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
      bodyFace.font(size * factor, weight, style)
    }

    /// The mono face at a size stated against Chalk's 17pt body.
    func mono(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
      monoFace.font(size * factor, weight, style)
    }

    /// An SF Symbol at a size stated against Chalk's 17pt body.
    func glyph(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
      .system(size: size * factor, weight: weight)
    }

    /// The body or mono face as a UIKit font, scaled for Dynamic Type — for
    /// the UIKit chrome.
    func uiFont(_ size: CGFloat, weight: UIFont.Weight = .regular, mono: Bool = false) -> UIFont {
      (mono ? monoFace : bodyFace).uiFont(size, weight: weight)
    }

    static func == (lhs: TypeSet, rhs: TypeSet) -> Bool {
      lhs.scale == rhs.scale && lhs.microLabel == rhs.microLabel && lhs.bodyFace == rhs.bodyFace
        && lhs.displayFace == rhs.displayFace && lhs.monoFace == rhs.monoFace
    }
  }

  /// The small label on section headers, column heads and chips.
  struct MicroLabel: Equatable {
    let font: Font
    let tracking: CGFloat
    let isUppercased: Bool
    let role: ThemeColorRole
    private let specification: ThemeMicroLabel

    init(_ label: ThemeMicroLabel, face: ResolvedFace) {
      specification = label
      font = face.font(label.size, label.weight.fontWeight, .caption)
      tracking = label.trackingPoints
      isUppercased = label.isUppercased
      role = label.role
    }

    static func == (lhs: MicroLabel, rhs: MicroLabel) -> Bool { lhs.specification == rhs.specification }
  }

  /// A face request settled against what is installed: the first named
  /// family the app can draw, or the design's system face.
  struct ResolvedFace: Equatable {
    let family: String?
    let design: Font.Design

    private static let installedFamilies = Set(UIFont.familyNames)

    init(_ face: ThemeFontFace) {
      family = face.families.first { Self.installedFamilies.contains($0) }
      design = face.design.fontDesign
    }

    func font(_ size: CGFloat, _ weight: Font.Weight, _ style: Font.TextStyle) -> Font {
      if let family { return .custom(family, size: size, relativeTo: style).weight(weight) }
      return Font(UIFontMetrics(forTextStyle: style.uiTextStyle).scaledFont(for: systemFont(size, weight.uiWeight)))
        .weight(weight)
    }

    func uiFont(_ size: CGFloat, weight: UIFont.Weight) -> UIFont {
      let font: UIFont
      if let family {
        let descriptor = UIFontDescriptor(fontAttributes: [
          .family: family, .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        font = UIFont(descriptor: descriptor, size: size)
      } else {
        font = systemFont(size, weight)
      }
      return UIFontMetrics.default.scaledFont(for: font)
    }

    private func systemFont(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
      let base = UIFont.systemFont(ofSize: size, weight: weight)
      let systemDesign: UIFontDescriptor.SystemDesign =
        switch design {
        case .serif: .serif
        case .monospaced: .monospaced
        case .rounded: .rounded
        default: .default
        }
      guard let descriptor = base.fontDescriptor.withDesign(systemDesign) else { return base }
      return UIFont(descriptor: descriptor, size: size)
    }
  }
}

extension ThemeFontDesign {
  var fontDesign: Font.Design {
    switch self {
    case .serif: .serif
    case .sans: .default
    case .monospaced: .monospaced
    case .rounded: .rounded
    }
  }
}

extension ThemeFontWeight {
  var fontWeight: Font.Weight {
    switch self {
    case .regular: .regular
    case .medium: .medium
    case .semibold: .semibold
    case .bold: .bold
    case .black: .black
    }
  }
}

extension Font.Weight {
  var uiWeight: UIFont.Weight {
    switch self {
    case .ultraLight: .ultraLight
    case .thin: .thin
    case .light: .light
    case .medium: .medium
    case .semibold: .semibold
    case .bold: .bold
    case .heavy: .heavy
    case .black: .black
    default: .regular
    }
  }
}

extension Font.TextStyle {
  var uiTextStyle: UIFont.TextStyle {
    switch self {
    case .largeTitle: .largeTitle
    case .title: .title1
    case .title2: .title2
    case .title3: .title3
    case .headline: .headline
    case .subheadline: .subheadline
    case .callout: .callout
    case .footnote: .footnote
    case .caption: .caption1
    case .caption2: .caption2
    default: .body
    }
  }
}

// MARK: - Environment

private struct ThemeKey: EnvironmentKey {
  static let defaultValue = Theme.chalk
}

extension EnvironmentValues {
  var theme: Theme {
    get { self[ThemeKey.self] }
    set { self[ThemeKey.self] = newValue }
  }
}

// MARK: - Per-platform structure

/// A theme's structure as the iPhone draws it.
///
/// docs/themes.md gives Chalk different sizes per platform — 17pt body text
/// and 44pt hit targets in the hand, 13pt at a desk — and PriorityCore is
/// gaining a `platforms` layer that resolves them. Until it lands, this lays
/// the iOS column of that table over any group a theme inherited from Chalk
/// unchanged, so a theme that only changes colours gets the phone's sizes
/// and one that sets its own keeps them.
enum PlatformStructure {
  struct Resolved: Equatable {
    let structure: ThemeStructure
    let touchTarget: CGFloat
  }

  /// The iOS column of "Chalk's defaults per platform".
  static let iOSScale = ThemeTypeScale(caption: 13, body: 17, title: 20, display: 34, hero: 72)
  static let iOSBodySize: Double = 17
  static let iOSMicroLabelSize: Double = 13
  static let iOSTouchTarget: CGFloat = 44

  static func resolve(_ specification: ThemeSpecification) -> Resolved {
    let chalk = BuiltInThemeSpecifications.chalk.structure
    let own = specification.structure
    let radius =
      own.radius == chalk.radius
      ? ThemeRadiusScale(panel: 8, row: 0, control: 6, pill: own.radius.pill, shell: own.radius.shell)
      : own.radius
    var typography = own.typography
    if typography.bodySize == chalk.typography.bodySize, typography.scale == chalk.typography.scale {
      let label = typography.microLabel
      let microLabel =
        label.size == chalk.typography.microLabel.size
        ? ThemeMicroLabel(
          size: iOSMicroLabelSize, weight: label.weight, tracking: label.tracking,
          isUppercased: label.isUppercased, role: label.role)
        : label
      typography = ThemeTypography(
        display: typography.display, body: typography.body, mono: typography.mono,
        bodySize: iOSBodySize, scale: iOSScale, microLabel: microLabel)
    }
    let structure = ThemeStructure(
      radius: radius, border: own.border, spacing: own.spacing, typography: typography,
      usesShadows: own.usesShadows, usesGradientsOnChrome: own.usesGradientsOnChrome)
    return Resolved(structure: structure, touchTarget: iOSTouchTarget)
  }
}

// MARK: - Layout constants

/// Sizes that belong to one layout rather than to the theme.
enum Metrics {
  /// Indent per outline level. Narrower than the Mac's, because a phone runs
  /// out of width four levels down.
  static let indent: CGFloat = 18
}

/// The colours a list can be given, in the order the picker offers them.
/// These are data — a list keeps its hex — not theme roles.
enum ListColor {
  static let choices: [(name: String, hex: String)] = [
    ("Azure", "#007fff"), ("Emerald", "#4cc38e"), ("Raspberry", "#d62246"), ("Amber", "#ffbf00"),
    ("Purple", "#7a4de8"), ("Pink", "#ff88dc"), ("Orange", "#ff6b2b"), ("Grape", "#444054"),
  ]

  static func color(hex: String?) -> Color? {
    guard let hex, let value = ThemeColorValue(hex: hex) else { return nil }
    return Color(red: value.red, green: value.green, blue: value.blue, opacity: value.alpha)
  }
}

// MARK: - Hit targets

extension View {
  /// Grows the tappable area to the theme's touch target without growing
  /// what is painted or how it is laid out: only the content shape reaches
  /// past the control's edges.
  func hitTarget() -> some View { modifier(HitTargetModifier()) }
}

private struct HitTargetModifier: ViewModifier {
  @Environment(\.theme) private var theme

  func body(content: Content) -> some View {
    content.contentShape(HitArea(minimum: theme.touchTarget))
  }
}

/// A rectangle at least `minimum` on each side, centred on the view it
/// shapes. Zero (a pointer platform) leaves the view's own bounds.
struct HitArea: Shape {
  var minimum: CGFloat

  func path(in rect: CGRect) -> Path {
    Path(
      rect.insetBy(
        dx: -max(0, (minimum - rect.width) / 2), dy: -max(0, (minimum - rect.height) / 2)))
  }
}
