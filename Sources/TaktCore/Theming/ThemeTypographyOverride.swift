import Foundation

/// The reader's own type choices, laid over whichever theme is in force.
///
/// A theme says what the faces and sizes are; this says "but set the body in
/// Inter, and a size up". It is kept apart from the theme so that switching
/// theme keeps the choices, and clearing it ("Reset to theme") hands every
/// role back to the theme without touching the theme's file.
///
/// It is applied through `ThemeFileLoader.merge` — the same overlay a theme
/// file's own `structure` goes through — so a family chosen here is resolved
/// exactly the way a family named in a theme file would be: tried first, with
/// the theme's own families and design behind it as the fallback.
public struct ThemeTypographyOverride: Codable, Equatable, Sendable {
  /// Interface text: rows, fields, captions, micro-labels.
  public var bodyFamily: String?
  /// Headings and pane titles.
  public var displayFamily: String?
  /// Numerals, key caps, code and the clock.
  public var monoFamily: String?
  /// A multiplier on the theme's body size and every step of its type scale,
  /// so the theme's proportions survive. `nil` or 1 leaves sizes alone.
  public var textScale: Double?

  public init(
    bodyFamily: String? = nil,
    displayFamily: String? = nil,
    monoFamily: String? = nil,
    textScale: Double? = nil
  ) {
    self.bodyFamily = bodyFamily
    self.displayFamily = displayFamily
    self.monoFamily = monoFamily
    self.textScale = textScale
  }

  /// The smallest and largest text size on offer. Below this captions stop
  /// being legible; above it the window's fixed-width columns stop fitting.
  public static let textScaleRange: ClosedRange<Double> = 0.85...1.3

  /// The text size actually applied: clamped, and 1 when unset.
  public var effectiveTextScale: Double {
    guard let textScale, textScale.isFinite else { return 1 }
    return min(max(textScale, Self.textScaleRange.lowerBound), Self.textScaleRange.upperBound)
  }

  /// True when nothing is overridden, so the theme renders as it ships.
  public var isEmpty: Bool {
    Self.cleaned(bodyFamily) == nil && Self.cleaned(displayFamily) == nil
      && Self.cleaned(monoFamily) == nil && effectiveTextScale == 1
  }

  /// The override as the partial structure a theme file would state.
  public func structureOverlay(over base: ThemeTypography) -> ThemeFile.Structure? {
    guard !isEmpty else { return nil }
    func face(_ family: String?, _ base: ThemeFontFace) -> ThemeFile.Face? {
      guard let family = Self.cleaned(family) else { return nil }
      // The choice first, then the theme's own request behind it, so a face
      // that is later uninstalled falls back to the theme rather than to the
      // system.
      let families = [family] + base.families.filter { $0 != family }
      return ThemeFile.Face(families: families, design: base.design.rawValue)
    }
    let factor = effectiveTextScale
    var bodySize: Double?
    var scale: ThemeFile.TypeScale?
    var microLabel: ThemeFile.MicroLabel?
    if factor != 1 {
      func scaled(_ value: Double) -> Double { (value * factor * 2).rounded() / 2 }
      bodySize = scaled(base.bodySize)
      scale = ThemeFile.TypeScale(
        caption: scaled(base.scale.caption),
        body: scaled(base.scale.body),
        title: scaled(base.scale.title),
        display: scaled(base.scale.display),
        hero: scaled(base.scale.hero))
      microLabel = ThemeFile.MicroLabel(size: scaled(base.microLabel.size))
    }
    return ThemeFile.Structure(
      typography: ThemeFile.Typography(
        display: face(displayFamily, base.display),
        body: face(bodyFamily, base.body),
        mono: face(monoFamily, base.mono),
        bodySize: bodySize,
        scale: scale,
        microLabel: microLabel))
  }

  /// `specification` with these choices laid over its typography. Everything
  /// else — identity, palette, radii, spacing — is the theme's.
  public func applied(to specification: ThemeSpecification) -> ThemeSpecification {
    guard let overlay = structureOverlay(over: specification.structure.typography) else {
      return specification
    }
    return ThemeSpecification(
      identifier: specification.identifier,
      name: specification.name,
      summary: specification.summary,
      lockedAppearance: specification.lockedAppearance,
      palette: specification.palette,
      structure: ThemeFileLoader.merge(overlay, over: specification.structure))
  }

  private static func cleaned(_ family: String?) -> String? {
    guard let trimmed = family?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed
  }
}

/// A family the apps ship, so choosing it looks the same on every device.
public struct BundledFontFamily: Equatable, Sendable, Identifiable {
  public let name: String
  public let design: ThemeFontDesign
  /// One line on what it is for, shown beside its preview.
  public let note: String

  public var id: String { name }

  public init(name: String, design: ThemeFontDesign, note: String) {
    self.name = name
    self.design = design
    self.note = note
  }

  /// Every family registered at launch from the app's own font files, in the
  /// order a picker lists them: sans, serif, then monospaced.
  public static let all: [BundledFontFamily] = [
    .init(name: "IBM Plex Sans", design: .sans, note: "Zed's interface face; humanist and compact"),
    .init(name: "Inter", design: .sans, note: "Neutral screen sans with tabular figures"),
    .init(name: "Geist", design: .sans, note: "Geometric and crisp at small sizes"),
    .init(name: "Arvo", design: .serif, note: "Slab serif; the Grape house face"),
    .init(name: "Lilex", design: .monospaced, note: "Zed's monospace, with ligatures"),
    .init(name: "JetBrains Mono", design: .monospaced, note: "Tall x-height code face"),
    .init(name: "Geist Mono", design: .monospaced, note: "Geist's monospaced companion"),
  ]

  public static func named(_ name: String) -> BundledFontFamily? {
    all.first { $0.name == name }
  }
}
