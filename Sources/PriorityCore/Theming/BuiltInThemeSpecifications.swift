import Foundation

/// The themes that ship with the app.
///
/// They live here, in `PriorityCore`, rather than in the plugins that vend
/// them: a palette is arithmetic, and arithmetic is the part worth testing.
/// `Priority/Plugins/Native/Theme/` is a pair of four-line wrappers over these
/// two values.
public enum BuiltInThemeSpecifications {
  public static let chalkIdentifier = "native.theme.chalk"
  public static let chalkDarkIdentifier = "native.theme.chalk.dark"

  /// The built-ins as the Mac resolves them.
  public static var all: [ThemeSpecification] { [chalk, chalkDark] }

  /// The built-ins as `platform` resolves them: the same palettes, with
  /// Chalk's per-platform structure.
  public static func all(for platform: ThemePlatform) -> [ThemeSpecification] {
    [chalk(for: platform), chalkDark(for: platform)]
  }

  public static func specification(withIdentifier identifier: String) -> ThemeSpecification? {
    all.first { $0.identifier == identifier }
  }

  public static func specification(
    withIdentifier identifier: String, for platform: ThemePlatform
  ) -> ThemeSpecification? {
    all(for: platform).first { $0.identifier == identifier }
  }

  /// Chalk, resolved for `platform`. `chalk` is the macOS one.
  public static func chalk(for platform: ThemePlatform) -> ThemeSpecification {
    chalkByPlatform[platform] ?? chalk
  }

  /// Chalk Dark, resolved for `platform`. It extends Chalk, so it takes the
  /// same per-platform structure.
  public static func chalkDark(for platform: ThemePlatform) -> ThemeSpecification {
    chalkDarkByPlatform[platform] ?? chalkDark
  }

  // MARK: - Per platform

  /// What Chalk lays over its own structure on each platform: the table in
  /// `docs/themes.md`, "Chalk's defaults per platform". macOS has no entry,
  /// because Chalk's `structure` already *is* the Mac's — so the Mac renders
  /// exactly what it did before platforms existed.
  ///
  /// 13pt is right at a desk and too small in the hand: the phones take the
  /// platform's own body size (iOS's 17, Material's 16), round their panels
  /// and controls a little, and grow hit areas to the platform minimum.
  public static let chalkPlatformStructures: [ThemePlatform: ThemeFile.Structure] = [
    .ios: ThemeFile.Structure(
      radius: .init(panel: 8, row: 0, control: 6),
      spacing: .init(xxs: 2, xs: 4, sm: 8, md: 12, lg: 16, xl: 24),
      typography: .init(
        bodySize: 17,
        scale: .init(caption: 13, body: 17, title: 20, display: 34, hero: 72),
        microLabel: .init(size: 13)),
      touchTarget: 44),
    .android: ThemeFile.Structure(
      radius: .init(panel: 8, row: 0, control: 6),
      spacing: .init(xxs: 2, xs: 4, sm: 8, md: 12, lg: 16, xl: 24),
      typography: .init(
        bodySize: 16,
        scale: .init(caption: 12, body: 16, title: 20, display: 32, hero: 72),
        microLabel: .init(size: 12)),
      touchTarget: 48),
  ]

  private static let chalkByPlatform: [ThemePlatform: ThemeSpecification] = Dictionary(
    uniqueKeysWithValues: ThemePlatform.allCases.map { platform in
      (platform, withStructure(chalk, for: platform))
    })

  private static let chalkDarkByPlatform: [ThemePlatform: ThemeSpecification] = Dictionary(
    uniqueKeysWithValues: ThemePlatform.allCases.map { platform in
      (platform, withStructure(chalkDark, for: platform))
    })

  /// `specification` with Chalk's entry for `platform` laid over its
  /// structure, through the same merge a theme file's `platforms` goes
  /// through.
  private static func withStructure(
    _ specification: ThemeSpecification, for platform: ThemePlatform
  ) -> ThemeSpecification {
    ThemeSpecification(
      identifier: specification.identifier,
      name: specification.name,
      summary: specification.summary,
      lockedAppearance: specification.lockedAppearance,
      palette: specification.palette,
      structure: ThemeFileLoader.merge(
        chalkPlatformStructures[platform], over: specification.structure))
  }

  // MARK: - Chalk — the house style

  /// Flat, bordered, editorial: paper-white surfaces with a bruised-purple
  /// ink, separated by hairlines rather than depth.
  ///
  /// The derived neutrals run warm at the paper end and cool at the ink end,
  /// the way real paper behaves — which is why `altRow` is warmer than `well`
  /// even though both are "a grey".
  public static let chalk = ThemeSpecification(
    identifier: chalkIdentifier,
    name: "Chalk",
    summary:
      "The house style. Warm off-white paper, grape ink, hairline borders, and colour kept for meaning.",
    palette: ThemePalette(
      light: [
        .paper: hex("#faf8f4"),
        .raised: hex("#ffffff"),
        .altRow: hex("#f5f3f1"),
        .hover: hex("#f1eff1"),
        .well: hex("#edebef"),
        .border: hex("#e6e4ea"),
        .borderMuted: hex("#efedf2"),
        .inputBorder: hex("#d8d5dd"),
        .ink: hex("#444054"),
        .mutedText: hex("#6e6b7c"),
        .dimText: hex("#b6b3bf"),
        .primary: azure,
        .success: emerald,
        .danger: raspberry,
        .warning: amber,
        .categoricalPurple: purple,
        .categoricalPink: pink,
        .categoricalOrange: orange,
        .mediaLetterbox: hex("#000000"),
        .mediaScrim: hex("#000000").withAlpha(0.7),
        .mediaScrimInk: hex("#ffffff"),
      ],
      dark: [
        // The same grape hue pulled down, never neutral grey.
        .paper: hex("#1c1a23"),
        .raised: hex("#25232f"),
        .altRow: hex("#211f29"),
        .hover: hex("#2d2b38"),
        .well: hex("#2d2b38"),
        .border: hex("#34313f"),
        .borderMuted: hex("#2d2b38"),
        .inputBorder: hex("#403d4d"),
        .ink: hex("#f5f4f7"),
        .mutedText: hex("#b6b3bf"),
        .dimText: hex("#6e6b7c"),
        // Accents keep their hex; the low-alpha fills are made at the point of
        // use, not baked in here.
        .primary: azure,
        .success: emerald,
        .danger: raspberry,
        .warning: amber,
        .categoricalPurple: purple,
        .categoricalPink: pink,
        .categoricalOrange: orange,
      ]
    ),
    structure: ThemeStructure(
      // Zed's "maximum utility": panels, overlays, cards and row selections
      // are square, and only the things you press keep a corner, small
      // enough to say "button" without saying "capsule".
      radius: ThemeRadiusScale(panel: 0, row: 0, control: 4, pill: 9999, shell: 20),
      border: ThemeBorderScale(hairline: 1, emphasis: 2, focusRing: 2),
      spacing: ThemeSpacingScale(xxs: 2, xs: 4, sm: 8, md: 12, lg: 16, xl: 24),
      typography: ThemeTypography(
        // Zed's pair, bundled with the app and registered at launch (see
        // `BundledFonts`): IBM Plex Sans for everything read, Lilex for code,
        // key caps and numerals. One clean sans at regular weight is most of
        // what makes Zed read as calm; the system sans and monospace are the
        // fallback if registration ever fails, so nothing lands in a serif.
        display: ThemeFontFace(families: ["IBM Plex Sans"], design: .sans),
        body: ThemeFontFace(families: ["IBM Plex Sans"], design: .sans),
        mono: ThemeFontFace(families: ["Lilex"], design: .monospaced),
        bodySize: 13,
        // Zed's proportions: 13 for body, a point under for captions, 15 for a
        // pane's heading. The two numeral sizes stay large — they are the
        // point of the screens they are on.
        scale: ThemeTypeScale(caption: 12, body: 13, title: 15, display: 28, hero: 64),
        // Labels the way Zed sets them: caption size, regular, as written,
        // untracked, muted. The old house micro-label — 10pt bold tracked
        // capitals — is a theme file away (see `docs/themes.md`); on every
        // header at once it shouted more than the content it was labelling.
        microLabel: ThemeMicroLabel(
          size: 12, weight: .regular, tracking: 0, isUppercased: false, role: .mutedText)
      )
    )
  )

  // MARK: - Chalk Dark

  /// Chalk, in the dark. Not a second palette — literally the same one, with
  /// the appearance fixed so that picking it means picking dark.
  ///
  /// The house style already specifies its own dark values: the grape hue
  /// pulled down rather than turned grey, page `#1c1a23`, raised `#25232f`,
  /// border `#34313f`, and the accents keeping their hex so that meaning does
  /// not change with the lights. All of that is in `chalk.palette` already,
  /// which is why this shares it rather than restating it — a second copy of
  /// the same hexes is a second thing to keep right.
  ///
  /// It replaces an invented high-contrast theme that existed only to prove
  /// the picker worked. A theme nobody chose the colours for is a theme nobody
  /// wants; this one was specified before the picker existed.
  public static let chalkDark = ThemeSpecification(
    identifier: chalkDarkIdentifier,
    name: "Chalk Dark",
    summary:
      "The house style with the lights off. The same grape hue pulled down, never neutral grey.",
    lockedAppearance: .dark,
    palette: chalk.palette,
    structure: chalk.structure
  )

  // MARK: - The palette layer

  static let azure = hex("#007fff")
  static let emerald = hex("#4cc38e")
  static let raspberry = hex("#d62246")
  static let amber = hex("#ffbf00")
  static let purple = hex("#7a4de8")
  static let pink = hex("#ff88dc")
  static let orange = hex("#ff6b2b")

  /// Literal hex, resolved once. A typo lands as `.unresolved` magenta rather
  /// than as a crash, and `ThemeSpecificationTests` asserts no built-in theme
  /// contains one.
  private static func hex(_ value: String) -> ThemeColorValue {
    ThemeColorValue(hex: value) ?? .unresolved
  }
}
