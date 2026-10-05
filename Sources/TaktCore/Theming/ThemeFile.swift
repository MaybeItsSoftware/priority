import Foundation

/// A theme as a user writes one: a JSON document in
/// `~/Library/Application Support/Takt/themes/`, every field optional.
///
/// This is the *file*, not the theme. Everything in it is a partial override
/// of the theme it `extends` — Chalk unless it says otherwise — so a file that
/// changes one colour is one line of palette. `ThemeFileLoader` does the
/// merging and turns the result into a `ThemeSpecification`.
///
/// The enumerated values (appearances, font designs, weights, colour roles)
/// are carried as strings on purpose. Decoding them as the enums would make a
/// single typo fail the whole document; carried as strings, a bad one is one
/// reported issue and the rest of the file still applies. The format is in
/// `docs/themes.md`.
public struct ThemeFile: Codable, Equatable, Sendable {
  /// What the file inherits every value it does not state from.
  public enum Base: Equatable, Sendable {
    /// Key absent: the default theme, Chalk.
    case defaultTheme
    /// `"extends": "<identifier>"` — a built-in or another user theme.
    case theme(String)
    /// `"extends": null` — no colours are inherited, so the file has to give
    /// every role itself. Structure still falls back to Chalk's, since a
    /// missing radius cannot leave anything unpainted.
    case nothing
  }

  /// `lockedAppearance`, which needs three states: inherit it, clear it, or
  /// set it. Absent, `null`, and `"light"`/`"dark"` respectively.
  public enum Lock: Equatable, Sendable {
    case inherit
    case unlocked
    /// Carried raw so an unknown value is a reported issue, not a decode
    /// failure.
    case locked(String)
  }

  public var identifier: String?
  public var name: String?
  public var summary: String?
  public var lockedAppearance: Lock
  public var extends: Base
  /// A few colours per appearance the palette is grown from; see
  /// `ThemeSeeds`. Laid under `palette`, which still wins role by role.
  public var seeds: Palette?
  public var palette: Palette?
  public var structure: Structure?
  /// Per-platform structure, laid over `structure` on that platform only.
  public var platforms: Platforms?

  public init(
    identifier: String? = nil,
    name: String? = nil,
    summary: String? = nil,
    lockedAppearance: Lock = .inherit,
    extends: Base = .defaultTheme,
    seeds: Palette? = nil,
    palette: Palette? = nil,
    structure: Structure? = nil,
    platforms: Platforms? = nil
  ) {
    self.identifier = identifier
    self.name = name
    self.summary = summary
    self.lockedAppearance = lockedAppearance
    self.extends = extends
    self.seeds = seeds
    self.palette = palette
    self.structure = structure
    self.platforms = platforms
  }

  // MARK: - Sections

  /// Name → hex, per appearance: a role name under `palette`, a seed name
  /// under `seeds`. `#rgb`, `#rrggbb` or `#rrggbbaa`; the last two digits of
  /// the eight-digit form are alpha.
  public struct Palette: Codable, Equatable, Sendable {
    public var light: [String: String]?
    public var dark: [String: String]?

    public init(light: [String: String]? = nil, dark: [String: String]? = nil) {
      self.light = light
      self.dark = dark
    }

    public subscript(appearance: ThemeAppearance) -> [String: String]? {
      appearance == .light ? light : dark
    }
  }

  public struct Radius: Codable, Equatable, Sendable {
    public var panel: Double?
    public var row: Double?
    public var control: Double?
    public var pill: Double?
    public var shell: Double?

    public init(
      panel: Double? = nil, row: Double? = nil, control: Double? = nil,
      pill: Double? = nil, shell: Double? = nil
    ) {
      self.panel = panel
      self.row = row
      self.control = control
      self.pill = pill
      self.shell = shell
    }
  }

  public struct Border: Codable, Equatable, Sendable {
    public var hairline: Double?
    public var emphasis: Double?
    public var focusRing: Double?

    public init(hairline: Double? = nil, emphasis: Double? = nil, focusRing: Double? = nil) {
      self.hairline = hairline
      self.emphasis = emphasis
      self.focusRing = focusRing
    }
  }

  public struct Spacing: Codable, Equatable, Sendable {
    public var xxs: Double?
    public var xs: Double?
    public var sm: Double?
    public var md: Double?
    public var lg: Double?
    public var xl: Double?

    public init(
      xxs: Double? = nil, xs: Double? = nil, sm: Double? = nil,
      md: Double? = nil, lg: Double? = nil, xl: Double? = nil
    ) {
      self.xxs = xxs
      self.xs = xs
      self.sm = sm
      self.md = md
      self.lg = lg
      self.xl = xl
    }
  }

  public struct Face: Codable, Equatable, Sendable {
    public var families: [String]?
    /// `serif`, `sans`, `monospaced` or `rounded`.
    public var design: String?

    public init(families: [String]? = nil, design: String? = nil) {
      self.families = families
      self.design = design
    }
  }

  public struct TypeScale: Codable, Equatable, Sendable {
    public var caption: Double?
    public var body: Double?
    public var title: Double?
    public var display: Double?
    public var hero: Double?

    public init(
      caption: Double? = nil, body: Double? = nil, title: Double? = nil,
      display: Double? = nil, hero: Double? = nil
    ) {
      self.caption = caption
      self.body = body
      self.title = title
      self.display = display
      self.hero = hero
    }
  }

  public struct MicroLabel: Codable, Equatable, Sendable {
    public var size: Double?
    /// `regular`, `medium`, `semibold`, `bold` or `black`.
    public var weight: String?
    /// In em, as the house style states it.
    public var tracking: Double?
    public var uppercase: Bool?
    /// A colour role name.
    public var role: String?

    public init(
      size: Double? = nil, weight: String? = nil, tracking: Double? = nil,
      uppercase: Bool? = nil, role: String? = nil
    ) {
      self.size = size
      self.weight = weight
      self.tracking = tracking
      self.uppercase = uppercase
      self.role = role
    }
  }

  public struct Typography: Codable, Equatable, Sendable {
    public var display: Face?
    public var body: Face?
    public var mono: Face?
    public var bodySize: Double?
    public var scale: TypeScale?
    public var microLabel: MicroLabel?

    public init(
      display: Face? = nil, body: Face? = nil, mono: Face? = nil, bodySize: Double? = nil,
      scale: TypeScale? = nil, microLabel: MicroLabel? = nil
    ) {
      self.display = display
      self.body = body
      self.mono = mono
      self.bodySize = bodySize
      self.scale = scale
      self.microLabel = microLabel
    }
  }

  public struct Structure: Codable, Equatable, Sendable {
    public var radius: Radius?
    public var border: Border?
    public var spacing: Spacing?
    public var typography: Typography?
    /// The minimum hit area, in points. 0 for a pointer platform.
    public var touchTarget: Double?
    public var usesShadows: Bool?
    public var usesGradientsOnChrome: Bool?

    public init(
      radius: Radius? = nil, border: Border? = nil, spacing: Spacing? = nil,
      typography: Typography? = nil, touchTarget: Double? = nil, usesShadows: Bool? = nil,
      usesGradientsOnChrome: Bool? = nil
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

  /// One platform's entry under `platforms`: a partial structure and nothing
  /// else. Colour is deliberately absent — a `palette` here is reported and
  /// ignored, because the point is that a role is one colour everywhere.
  public struct PlatformOverride: Codable, Equatable, Sendable {
    public var structure: Structure?

    public init(structure: Structure? = nil) {
      self.structure = structure
    }
  }

  /// `platforms.macos`, `platforms.ios` and `platforms.android`.
  public struct Platforms: Codable, Equatable, Sendable {
    public var macos: PlatformOverride?
    public var ios: PlatformOverride?
    public var android: PlatformOverride?

    public init(
      macos: PlatformOverride? = nil, ios: PlatformOverride? = nil, android: PlatformOverride? = nil
    ) {
      self.macos = macos
      self.ios = ios
      self.android = android
    }

    public subscript(platform: ThemePlatform) -> PlatformOverride? {
      get {
        switch platform {
        case .macos: return macos
        case .ios: return ios
        case .android: return android
        }
      }
      set {
        switch platform {
        case .macos: macos = newValue
        case .ios: ios = newValue
        case .android: android = newValue
        }
      }
    }

    var isEmpty: Bool { macos == nil && ios == nil && android == nil }
  }

  // MARK: - Coding

  enum CodingKeys: String, CodingKey, CaseIterable {
    case identifier, name, summary, lockedAppearance, extends, seeds, palette, structure, platforms
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
    name = try container.decodeIfPresent(String.self, forKey: .name)
    summary = try container.decodeIfPresent(String.self, forKey: .summary)
    seeds = try container.decodeIfPresent(Palette.self, forKey: .seeds)
    palette = try container.decodeIfPresent(Palette.self, forKey: .palette)
    structure = try container.decodeIfPresent(Structure.self, forKey: .structure)
    platforms = try container.decodeIfPresent(Platforms.self, forKey: .platforms)

    // Absent and `null` mean different things for these two, which the
    // synthesised conformance cannot tell apart.
    if !container.contains(.extends) {
      extends = .defaultTheme
    } else if try container.decodeNil(forKey: .extends) {
      extends = .nothing
    } else {
      extends = .theme(try container.decode(String.self, forKey: .extends))
    }

    if !container.contains(.lockedAppearance) {
      lockedAppearance = .inherit
    } else if try container.decodeNil(forKey: .lockedAppearance) {
      lockedAppearance = .unlocked
    } else {
      lockedAppearance = .locked(try container.decode(String.self, forKey: .lockedAppearance))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(identifier, forKey: .identifier)
    try container.encodeIfPresent(name, forKey: .name)
    try container.encodeIfPresent(summary, forKey: .summary)
    try container.encodeIfPresent(seeds, forKey: .seeds)
    try container.encodeIfPresent(palette, forKey: .palette)
    try container.encodeIfPresent(structure, forKey: .structure)
    try container.encodeIfPresent(platforms, forKey: .platforms)
    switch extends {
    case .defaultTheme: break
    case .theme(let identifier): try container.encode(identifier, forKey: .extends)
    case .nothing: try container.encodeNil(forKey: .extends)
    }
    switch lockedAppearance {
    case .inherit: break
    case .unlocked: try container.encodeNil(forKey: .lockedAppearance)
    case .locked(let raw): try container.encode(raw, forKey: .lockedAppearance)
    }
  }
}

// MARK: - From a specification

extension ThemeFile {
  /// Every value of `specification`, stated explicitly — the file the "export
  /// current theme" command writes. It still extends the default theme, so a
  /// role added in a later release inherits Chalk's value rather than going
  /// missing from an old export.
  ///
  /// `specification` is the theme as resolved for one platform, and its
  /// structure becomes the file's `structure`. `platformVariants` are the same
  /// theme resolved for other platforms; each one that differs is written as
  /// the smallest `platforms.<platform>.structure` that gets back to it, so
  /// the file resolves to the same theme on every platform it was given for.
  public init(
    specification: ThemeSpecification,
    platformVariants: [ThemePlatform: ThemeSpecification] = [:]
  ) {
    func table(_ values: [ThemeColorRole: ThemeColorValue]) -> [String: String] {
      Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value.hexString.lowercased()) })
    }
    var platforms = Platforms()
    for platform in ThemePlatform.allCases {
      guard let variant = platformVariants[platform],
        let difference = Structure.difference(from: specification.structure, to: variant.structure)
      else { continue }
      platforms[platform] = PlatformOverride(structure: difference)
    }
    self.init(
      identifier: specification.identifier,
      name: specification.name,
      summary: specification.summary,
      lockedAppearance: specification.lockedAppearance.map { .locked($0.rawValue) } ?? .unlocked,
      extends: .defaultTheme,
      palette: Palette(
        light: table(specification.palette.light), dark: table(specification.palette.dark)),
      structure: Structure(specification.structure),
      platforms: platforms.isEmpty ? nil : platforms
    )
  }

  /// Pretty-printed, keys sorted, so an export diffs cleanly.
  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }
}

// MARK: - Structure, stated

extension ThemeFile.Structure {
  /// Every value of `structure`, stated.
  public init(_ structure: ThemeStructure) {
    let type = structure.typography
    self.init(
      radius: .init(
        panel: structure.radius.panel, row: structure.radius.row, control: structure.radius.control,
        pill: structure.radius.pill, shell: structure.radius.shell),
      border: .init(
        hairline: structure.border.hairline, emphasis: structure.border.emphasis,
        focusRing: structure.border.focusRing),
      spacing: .init(
        xxs: structure.spacing.xxs, xs: structure.spacing.xs, sm: structure.spacing.sm,
        md: structure.spacing.md, lg: structure.spacing.lg, xl: structure.spacing.xl),
      typography: .init(
        display: .init(type.display),
        body: .init(type.body),
        mono: .init(type.mono),
        bodySize: type.bodySize,
        scale: .init(
          caption: type.scale.caption, body: type.scale.body, title: type.scale.title,
          display: type.scale.display, hero: type.scale.hero),
        microLabel: .init(
          size: type.microLabel.size, weight: type.microLabel.weight.rawValue,
          tracking: type.microLabel.tracking, uppercase: type.microLabel.isUppercased,
          role: type.microLabel.role.rawValue)),
      touchTarget: structure.touchTarget,
      usesShadows: structure.usesShadows,
      usesGradientsOnChrome: structure.usesGradientsOnChrome)
  }

  /// The smallest partial structure that, laid over `base`, gives `target`;
  /// `nil` when they are the same.
  ///
  /// A changed body size carries the whole scale with it: laying a new
  /// `bodySize` re-proportions every step it does not state, so stating only
  /// the steps that differ would land the others somewhere neither theme has.
  public static func difference(from base: ThemeStructure, to target: ThemeStructure) -> Self? {
    func changed<T: Equatable>(_ old: T, _ new: T) -> T? { old == new ? nil : new }

    let radius = ThemeFile.Radius(
      panel: changed(base.radius.panel, target.radius.panel),
      row: changed(base.radius.row, target.radius.row),
      control: changed(base.radius.control, target.radius.control),
      pill: changed(base.radius.pill, target.radius.pill),
      shell: changed(base.radius.shell, target.radius.shell))
    let border = ThemeFile.Border(
      hairline: changed(base.border.hairline, target.border.hairline),
      emphasis: changed(base.border.emphasis, target.border.emphasis),
      focusRing: changed(base.border.focusRing, target.border.focusRing))
    let spacing = ThemeFile.Spacing(
      xxs: changed(base.spacing.xxs, target.spacing.xxs),
      xs: changed(base.spacing.xs, target.spacing.xs),
      sm: changed(base.spacing.sm, target.spacing.sm),
      md: changed(base.spacing.md, target.spacing.md),
      lg: changed(base.spacing.lg, target.spacing.lg),
      xl: changed(base.spacing.xl, target.spacing.xl))

    let old = base.typography
    let new = target.typography
    let bodySize = changed(old.bodySize, new.bodySize)
    let scale: ThemeFile.TypeScale
    if bodySize != nil {
      scale = .init(
        caption: new.scale.caption, body: new.scale.body, title: new.scale.title,
        display: new.scale.display, hero: new.scale.hero)
    } else {
      scale = .init(
        caption: changed(old.scale.caption, new.scale.caption),
        body: changed(old.scale.body, new.scale.body),
        title: changed(old.scale.title, new.scale.title),
        display: changed(old.scale.display, new.scale.display),
        hero: changed(old.scale.hero, new.scale.hero))
    }
    let microLabel = ThemeFile.MicroLabel(
      size: changed(old.microLabel.size, new.microLabel.size),
      weight: changed(old.microLabel.weight, new.microLabel.weight)?.rawValue,
      tracking: changed(old.microLabel.tracking, new.microLabel.tracking),
      uppercase: changed(old.microLabel.isUppercased, new.microLabel.isUppercased),
      role: changed(old.microLabel.role, new.microLabel.role)?.rawValue)
    let typography = ThemeFile.Typography(
      display: changed(old.display, new.display).map(ThemeFile.Face.init),
      body: changed(old.body, new.body).map(ThemeFile.Face.init),
      mono: changed(old.mono, new.mono).map(ThemeFile.Face.init),
      bodySize: bodySize,
      scale: scale == .init() ? nil : scale,
      microLabel: microLabel == .init() ? nil : microLabel)

    let difference = Self(
      radius: radius == .init() ? nil : radius,
      border: border == .init() ? nil : border,
      spacing: spacing == .init() ? nil : spacing,
      typography: typography == .init() ? nil : typography,
      touchTarget: changed(base.touchTarget, target.touchTarget),
      usesShadows: changed(base.usesShadows, target.usesShadows),
      usesGradientsOnChrome: changed(base.usesGradientsOnChrome, target.usesGradientsOnChrome))
    return difference == .init() ? nil : difference
  }
}

extension ThemeFile.Face {
  public init(_ face: ThemeFontFace) {
    self.init(families: face.families, design: face.design.rawValue)
  }
}
