import Foundation

/// The themes that ship with the app.
///
/// They live here, in `PriorityCore`, rather than in the plugins that vend
/// them: a palette is arithmetic, and arithmetic is the part worth testing.
/// `Priority/Plugins/Native/Theme/` is a pair of four-line wrappers over these
/// two values.
public enum BuiltInThemeSpecifications {
  public static let chalkIdentifier = "native.theme.chalk"
  public static let pitchIdentifier = "native.theme.pitch"

  public static var all: [ThemeSpecification] { [chalk, pitch] }

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
        // Geist Mono are used if installed, and the design is the fallback.
        display: ThemeFontFace(families: ["Arvo"], design: .serif),
        body: ThemeFontFace(families: ["Arvo"], design: .serif),
        mono: ThemeFontFace(families: ["Geist Mono", "SF Mono"], design: .monospaced),
        bodySize: 13,
        microLabel: ThemeMicroLabel(
          size: 10, weight: .bold, tracking: 0.15, isUppercased: true, role: .mutedText)
      )
    )
  )

  // MARK: - Pitch — high contrast

  /// The same structure argued at maximum volume: near-black on white, ink
  /// hairlines at 2pt, radii nearly squared off, and every accent darkened or
  /// lightened until it clears AAA for body text.
  ///
  /// It exists to prove the swap is real. If a surface still looks like Chalk
  /// with Pitch selected, that surface has not been migrated.
  public static let pitch = ThemeSpecification(
    identifier: pitchIdentifier,
    name: "Pitch",
    summary:
      "High contrast, dark-forward. Squared corners, 2pt rules, and accents pushed to AAA against the page.",
    preferredAppearance: .dark,
    palette: ThemePalette(
      light: [
        .paper: hex("#ffffff"),
        .raised: hex("#f0f0f3"),
        .altRow: hex("#f5f5f7"),
        .hover: hex("#e6e6ec"),
        .well: hex("#e0e0e8"),
        .border: hex("#0b0b0f"),
        .borderMuted: hex("#8a8a96"),
        .inputBorder: hex("#0b0b0f"),
        .ink: hex("#0b0b0f"),
        .mutedText: hex("#2f2f3a"),
        .dimText: hex("#5a5a66"),
        .primary: hex("#0032c8"),
        .success: hex("#075c33"),
        .danger: hex("#a3001f"),
        .warning: hex("#6b4400"),
        .categoricalPurple: hex("#4b18b8"),
        .categoricalPink: hex("#a3006b"),
        .categoricalOrange: hex("#8a3300"),
        .mediaLetterbox: hex("#000000"),
        .mediaScrim: hex("#000000").withAlpha(0.8),
        .mediaScrimInk: hex("#ffffff"),
      ],
      dark: [
        .paper: hex("#000000"),
        .raised: hex("#121216"),
        .altRow: hex("#0a0a0d"),
        .hover: hex("#1e1e26"),
        .well: hex("#1e1e26"),
        .border: hex("#ffffff"),
        .borderMuted: hex("#6a6a76"),
        .inputBorder: hex("#ffffff"),
        .ink: hex("#ffffff"),
        .mutedText: hex("#d7d7de"),
        .dimText: hex("#9a9aa6"),
        .primary: hex("#7ab8ff"),
        .success: hex("#5fe3a1"),
        .danger: hex("#ff7a90"),
        .warning: hex("#ffd24d"),
        .categoricalPurple: hex("#b693ff"),
        .categoricalPink: hex("#ff9ede"),
        .categoricalOrange: hex("#ff9457"),
      ]
    ),
    structure: ThemeStructure(
      radius: ThemeRadiusScale(panel: 2, control: 2, pill: 9999, shell: 0),
      border: ThemeBorderScale(hairline: 2, emphasis: 3, focusRing: 3),
      spacing: ThemeSpacingScale(xxs: 2, xs: 4, sm: 8, md: 12, lg: 18, xl: 28),
      typography: ThemeTypography(
        display: ThemeFontFace(families: [], design: .sans),
        body: ThemeFontFace(families: [], design: .sans),
        mono: ThemeFontFace(families: ["Geist Mono", "SF Mono"], design: .monospaced),
        bodySize: 13,
        microLabel: ThemeMicroLabel(
          size: 10, weight: .black, tracking: 0.18, isUppercased: true, role: .mutedText)
      )
    )
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
