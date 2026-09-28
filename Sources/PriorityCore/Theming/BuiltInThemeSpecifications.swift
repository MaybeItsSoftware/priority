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

  public static var all: [ThemeSpecification] { [chalk, chalkDark] }

  public static func specification(withIdentifier identifier: String) -> ThemeSpecification? {
    all.first { $0.identifier == identifier }
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
      radius: ThemeRadiusScale(panel: 8, control: 6, pill: 9999, shell: 20),
      border: ThemeBorderScale(hairline: 1, emphasis: 2, focusRing: 2),
      spacing: ThemeSpacingScale(xxs: 2, xs: 4, sm: 8, md: 12, lg: 16, xl: 24),
      typography: ThemeTypography(
        // No font files ship with the app, so these are requests: Arvo and
        // Geist Mono are used if installed. Rockwell comes with macOS and is
        // a slab too, so the house style's character survives without Arvo;
        // the generic serif design is only the last resort.
        display: ThemeFontFace(families: ["Arvo", "Rockwell"], design: .serif),
        body: ThemeFontFace(families: ["Arvo", "Rockwell"], design: .serif),
        mono: ThemeFontFace(families: ["Geist Mono", "SF Mono"], design: .monospaced),
        bodySize: 13,
        scale: ThemeTypeScale(caption: 11, body: 13, title: 15, display: 28, hero: 64),
        microLabel: ThemeMicroLabel(
          size: 10, weight: .bold, tracking: 0.15, isUppercased: true, role: .mutedText)
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
