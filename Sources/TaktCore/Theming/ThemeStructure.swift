import Foundation

/// The one radius scale, as a closed set of five.
///
/// Rule 3 of the house style — "nothing between" — only holds if there is
/// nowhere to put an in-between value. A component asks for `.panel`, never
/// for `10`.
///
/// Zero is a legitimate value for `panel` and `row`, and the built-ins use
/// it: the window reads the way an editor's does, with overlays, cards and
/// selections as square as the panes they sit in. A theme that wants the
/// softer look back raises them.
public struct ThemeRadiusScale: Equatable, Sendable {
  /// Cards, panels, popovers.
  public let panel: Double
  /// A list row's selection and hover — the sidebar, the outline, every
  /// result list. Its own step because a row runs edge to edge of its pane,
  /// so whatever the pane's corners are, a rounded selection inside it reads
  /// as a box floating in the list rather than the line being chosen.
  public let row: Double
  /// Buttons, inputs, chips, tooltips.
  public let control: Double
  /// Pills, badges, avatars.
  public let pill: Double
  /// The outermost app shell, and nothing else.
  public let shell: Double

  public init(panel: Double, row: Double, control: Double, pill: Double, shell: Double) {
    self.panel = panel
    self.row = row
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
/// Every face is a *request*: the named families are tried in order against
/// what is installed — the app registers the faces it bundles at launch, so
/// the built-in themes' requests are always met — and the design is what you
/// get when none of them is, as a user theme naming an absent font does.
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

/// The micro-label: the small muted label on section headers, column heads,
/// chip captions and tab strips.
///
/// The built-in themes set it the way Zed does — caption size, regular, as
/// written, untracked. It used to be the house style's signature 10pt bold
/// uppercase at 0.15em, and every part of that is still a token, so a theme
/// can bring it back. Either way it is a first-class part of the theme rather
/// than a `.font(.caption2)` repeated forty times.
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

/// The handful of sizes the interface is allowed to use, by role.
///
/// Hierarchy is carried by surface and position, the micro-label and weight —
/// not by a ladder of sizes — so the scale is short on purpose. Views ask for
/// a role; a theme that wants a denser or roomier app changes it here.
public struct ThemeTypeScale: Equatable, Sendable {
  /// Secondary row text: metadata, counts, notes under a title.
  public let caption: Double
  /// Task titles, fields, most of the interface.
  public let body: Double
  /// A pane's heading.
  public let title: Double
  /// Large numerals that are the point of their screen — a running timer's
  /// seconds, a day's points total.
  public let display: Double
  /// The one number on a screen that is read from across the room: the focus
  /// timer.
  public let hero: Double

  public init(caption: Double, body: Double, title: Double, display: Double, hero: Double) {
    self.caption = caption
    self.body = body
    self.title = title
    self.display = display
    self.hero = hero
  }

  /// A scale proportioned from a body size, for themes that name only that.
  public static func proportioned(fromBody body: Double) -> ThemeTypeScale {
    ThemeTypeScale(
      caption: (body * 0.85).rounded(),
      body: body,
      title: (body * 1.25).rounded(),
      display: (body * 2.2).rounded(),
      hero: (body * 5).rounded())
  }
}

public struct ThemeTypography: Equatable, Sendable {
  /// Brand and display.
  public let display: ThemeFontFace
  /// Running text and task titles.
  public let body: ThemeFontFace
  /// Code, tickers, control-bar labels.
  public let mono: ThemeFontFace
  public let bodySize: Double
  public let scale: ThemeTypeScale
  public let microLabel: ThemeMicroLabel

  public init(
    display: ThemeFontFace,
    body: ThemeFontFace,
    mono: ThemeFontFace,
    bodySize: Double,
    scale: ThemeTypeScale? = nil,
    microLabel: ThemeMicroLabel
  ) {
    self.display = display
    self.body = body
    self.mono = mono
    self.bodySize = bodySize
    self.scale = scale ?? .proportioned(fromBody: bodySize)
    self.microLabel = microLabel
  }
}

/// Everything about a theme that is not colour.
public struct ThemeStructure: Equatable, Sendable {
  public let radius: ThemeRadiusScale
  public let border: ThemeBorderScale
  public let spacing: ThemeSpacingScale
  public let typography: ThemeTypography
  /// The minimum hit area a control is grown to, invisibly, so the painted
  /// control keeps its size. 0 is a pointer platform with no minimum; the
  /// built-ins set 44 on iOS and 48 on Android.
  public let touchTarget: Double
  /// Rule 1. A theme may declare otherwise, and `validate()` will say so.
  public let usesShadows: Bool
  /// Rule 2. Full-bleed backdrops are not chrome and are exempt.
  public let usesGradientsOnChrome: Bool

  public init(
    radius: ThemeRadiusScale,
    border: ThemeBorderScale,
    spacing: ThemeSpacingScale,
    typography: ThemeTypography,
    touchTarget: Double = 0,
    usesShadows: Bool = false,
    usesGradientsOnChrome: Bool = false
  ) {
    self.radius = radius
    self.border = border
    self.spacing = spacing
    self.typography = typography
    self.touchTarget = touchTarget
    self.usesShadows = usesShadows
    self.usesGradientsOnChrome = usesGradientsOnChrome
  }
}
