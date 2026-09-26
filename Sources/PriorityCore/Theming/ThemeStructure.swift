import Foundation

/// The one radius scale, as a closed set of four.
///
/// Rule 3 of the house style — "nothing between" — only holds if there is
/// nowhere to put an in-between value. A component asks for `.panel`, never
/// for `10`.
public struct ThemeRadiusScale: Equatable, Sendable {
  /// Cards, panels, popovers.
  public let panel: Double
  /// Buttons, inputs, chips, tooltips.
  public let control: Double
  /// Pills, badges, avatars.
  public let pill: Double
  /// The outermost app shell, and nothing else.
  public let shell: Double

  public init(panel: Double, control: Double, pill: Double, shell: Double) {
    self.panel = panel
    self.control = control
    self.pill = pill
    self.shell = shell
  }
}

/// Border weights. Separation comes from these, so a theme that wants more
/// structure raises them rather than reaching for a shadow.
public struct ThemeBorderScale: Equatable, Sendable {
  /// The default 1px rule.
  public let hairline: Double
  /// A heavier rule for a selected or active edge.
  public let emphasis: Double
  /// The focus ring, drawn in `.primary`.
  public let focusRing: Double

  public init(hairline: Double, emphasis: Double, focusRing: Double) {
    self.hairline = hairline
    self.emphasis = emphasis
    self.focusRing = focusRing
  }
}

/// A six-step spacing scale. Named rather than numeric so a denser theme can
/// compress the whole app by redefining six numbers.
public struct ThemeSpacingScale: Equatable, Sendable {
  public let xxs: Double
  public let xs: Double
  public let sm: Double
  public let md: Double
  public let lg: Double
  public let xl: Double

  public init(xxs: Double, xs: Double, sm: Double, md: Double, lg: Double, xl: Double) {
    self.xxs = xxs
    self.xs = xs
    self.sm = sm
    self.md = md
    self.lg = lg
    self.xl = xl
  }
}

/// What a face falls back to when none of its named fonts are installed.
///
/// Priority ships no font files, so every face is a *request*: the named
/// families are tried in order and the design is what you actually get until
/// somebody installs Arvo.
public enum ThemeFontDesign: String, Equatable, Sendable, Codable {
  case serif
  case sans
  case monospaced
  case rounded
}

public enum ThemeFontWeight: String, Equatable, Sendable, Codable {
  case regular
  case medium
  case semibold
  case bold
  case black
}

/// A named font request with a system fallback.
public struct ThemeFontFace: Equatable, Sendable {
  /// Family names, most-wanted first. Empty means "use the design".
  public let families: [String]
  public let design: ThemeFontDesign

  public init(families: [String], design: ThemeFontDesign) {
    self.families = families
    self.design = design
  }
}

/// The micro-label: 10pt, bold, uppercase, 0.15em tracking, muted.
///
/// The signature device of the house style, and the reason hierarchy here
/// comes from surface and position rather than from label size — so it is a
/// first-class part of the theme rather than a `.font(.caption2)` repeated
/// forty times.
public struct ThemeMicroLabel: Equatable, Sendable {
  public let size: Double
  public let weight: ThemeFontWeight
  /// Tracking in *em*, the way the house style states it.
  public let tracking: Double
  public let isUppercased: Bool
  public let role: ThemeColorRole

  public init(
    size: Double,
    weight: ThemeFontWeight,
    tracking: Double,
    isUppercased: Bool,
    role: ThemeColorRole
  ) {
    self.size = size
    self.weight = weight
    self.tracking = tracking
    self.isUppercased = isUppercased
    self.role = role
  }

  /// SwiftUI's `.tracking` is in points, the house style is in em. One
  /// conversion, in the layer that can be tested.
  public var trackingPoints: Double { size * tracking }
}

public struct ThemeTypography: Equatable, Sendable {
  /// Brand and display.
  public let display: ThemeFontFace
  /// Running text and task titles.
  public let body: ThemeFontFace
  /// Code, tickers, control-bar labels.
  public let mono: ThemeFontFace
  public let bodySize: Double
  public let microLabel: ThemeMicroLabel

  public init(
    display: ThemeFontFace,
    body: ThemeFontFace,
    mono: ThemeFontFace,
    bodySize: Double,
    microLabel: ThemeMicroLabel
  ) {
    self.display = display
    self.body = body
    self.mono = mono
    self.bodySize = bodySize
    self.microLabel = microLabel
  }
}

/// Everything about a theme that is not colour.
public struct ThemeStructure: Equatable, Sendable {
  public let radius: ThemeRadiusScale
  public let border: ThemeBorderScale
  public let spacing: ThemeSpacingScale
  public let typography: ThemeTypography
  /// Rule 1. A theme may declare otherwise, and `validate()` will say so.
  public let usesShadows: Bool
  /// Rule 2. Full-bleed backdrops are not chrome and are exempt.
  public let usesGradientsOnChrome: Bool

  public init(
    radius: ThemeRadiusScale,
    border: ThemeBorderScale,
    spacing: ThemeSpacingScale,
    typography: ThemeTypography,
    usesShadows: Bool = false,
    usesGradientsOnChrome: Bool = false
  ) {
    self.radius = radius
    self.border = border
    self.spacing = spacing
    self.typography = typography
    self.usesShadows = usesShadows
    self.usesGradientsOnChrome = usesGradientsOnChrome
  }
}
