import Foundation

/// The themes that ship with the app.
///
/// They live here, in `TaktCore`, rather than in the plugins that vend
/// them: a palette is arithmetic, and arithmetic is the part worth testing.
/// `Takt/Plugins/Native/Theme/` is a pair of four-line wrappers over these
/// two values.
public enum BuiltInThemeSpecifications {
  /// The default (shown as "Takt", stored as Priority): what a fresh install shows, what a theme file
  /// extends unless it says otherwise, and what stands in for a theme that
  /// will not load.
  public static let priorityIdentifier = "native.theme.priority"
  /// The Zed look. The identifiers still say Chalk, its old name, because
  /// they are stored as people's choice and synced between devices.
  public static let chalkIdentifier = "native.theme.chalk"
  public static let chalkDarkIdentifier = "native.theme.chalk.dark"
  /// Grape: the house design language, whole — Zed's palette with its own
  /// type, radii and labels rather than Zed's.
  public static let grapeIdentifier = "native.theme.grape"

  /// The identifier a device uses when nothing has been chosen.
  public static let defaultIdentifier = priorityIdentifier

  /// The built-ins as the Mac resolves them, the default first.
  public static var all: [ThemeSpecification] { [priority, chalk, chalkDark, grape] }

  /// The built-ins as `platform` resolves them: the same palettes, with each
  /// theme's per-platform structure.
  public static func all(for platform: ThemePlatform) -> [ThemeSpecification] {
    [priority(for: platform), chalk(for: platform), chalkDark(for: platform), grape(for: platform)]
  }

  /// The default theme, resolved for `platform`.
  public static func defaultTheme(for platform: ThemePlatform) -> ThemeSpecification {
    priority(for: platform)
  }

  /// The default, resolved for `platform`. `priority` is the macOS one.
  public static func priority(for platform: ThemePlatform) -> ThemeSpecification {
    priorityByPlatform[platform] ?? priority
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

  /// Grape, resolved for `platform`. `grape` is the macOS one.
  public static func grape(for platform: ThemePlatform) -> ThemeSpecification {
    grapeByPlatform[platform] ?? grape
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

  /// What the default lays over its own structure on each platform. The same
  /// type sizes as Chalk's on the phones, its own roomy spacing everywhere,
  /// and corners rounder again in the hand, the way the platforms' own cards
  /// and controls are.
  public static let priorityPlatformStructures: [ThemePlatform: ThemeFile.Structure] = [
    .ios: ThemeFile.Structure(
      radius: .init(panel: 14, row: 10, control: 10),
      typography: .init(
        bodySize: 17,
        scale: .init(caption: 13, body: 17, title: 20, display: 34, hero: 72),
        microLabel: .init(size: 13)),
      touchTarget: 44),
    .android: ThemeFile.Structure(
      radius: .init(panel: 16, row: 12, control: 10),
      typography: .init(
        bodySize: 16,
        scale: .init(caption: 12, body: 16, title: 20, display: 32, hero: 72),
        microLabel: .init(size: 12)),
      touchTarget: 48),
  ]

  /// Every built-in's per-platform structure, by identifier.
  public static let platformStructures: [String: [ThemePlatform: ThemeFile.Structure]] = [
    priorityIdentifier: priorityPlatformStructures,
    chalkIdentifier: chalkPlatformStructures,
    chalkDarkIdentifier: chalkPlatformStructures,
    grapeIdentifier: grapePlatformStructures,
  ]

  /// Grape on the phones: the platform body sizes, the same radius scale it
  /// has on the Mac, and hit areas grown to each platform's minimum. The
  /// micro-label stays 10pt — it is meant to be the smallest thing on screen.
  public static let grapePlatformStructures: [ThemePlatform: ThemeFile.Structure] = [
    .ios: ThemeFile.Structure(
      typography: .init(
        bodySize: 17,
        scale: .init(caption: 13, body: 17, title: 20, display: 34, hero: 72)),
      touchTarget: 44),
    .android: ThemeFile.Structure(
      typography: .init(
        bodySize: 16,
        scale: .init(caption: 12, body: 16, title: 20, display: 32, hero: 72)),
      touchTarget: 48),
  ]

  private static let priorityByPlatform = byPlatform(priority, priorityPlatformStructures)
  private static let chalkByPlatform = byPlatform(chalk, chalkPlatformStructures)
  private static let chalkDarkByPlatform = byPlatform(chalkDark, chalkPlatformStructures)
  private static let grapeByPlatform = byPlatform(grape, grapePlatformStructures)

  private static func byPlatform(
    _ specification: ThemeSpecification, _ structures: [ThemePlatform: ThemeFile.Structure]
  ) -> [ThemePlatform: ThemeSpecification] {
    Dictionary(
      uniqueKeysWithValues: ThemePlatform.allCases.map { platform in
        (platform, withStructure(specification, structures[platform]))
      })
  }

  /// `specification` with `structure` laid over its own, through the same
  /// merge a theme file's `platforms` goes through.
  private static func withStructure(
    _ specification: ThemeSpecification, _ structure: ThemeFile.Structure?
  ) -> ThemeSpecification {
    ThemeSpecification(
      identifier: specification.identifier,
      name: specification.name,
      summary: specification.summary,
      lockedAppearance: specification.lockedAppearance,
      palette: specification.palette,
      structure: ThemeFileLoader.merge(structure, over: specification.structure))
  }

  // MARK: - Takt (née Priority) — the default

  /// Friendly, roomy and rounded: the generic modern app, rather than an
  /// editor. Shown as "Takt"; the identifier still says Priority because it
  /// is stored as people's choice and synced between devices.
  ///
  /// - The house palette: chalk paper (`#faf8f4`) with white cards above it,
  ///   grape ink (`#444054`) that tints every grey and hairline, and azure
  ///   (`#007fff`) for actions, with emerald, raspberry and amber for status.
  /// - Dark is the same grape pulled down (`#1c1a23`), never neutral grey, and
  ///   the accents keep their hex.
  /// - Inter for everything read, Geist Mono for numerals and code; 12 on
  ///   cards, 8 on rows and what you press, and a more generous spacing scale
  ///   than the editor themes, which widens every gutter and row with it.
  ///
  /// It is still made the way a theme file is meant to be: from seeds — the
  /// page, the ink, the accent and the three status hues. The house palette
  /// then names its own neutrals by hand (warm at the paper end, cool at the
  /// ink end, the way paper is), and named roles win over grown ones, so it
  /// is exactly Zed's colours on the default's roomier structure.
  public static let priority = ThemeSpecification(
    identifier: priorityIdentifier,
    name: "Takt",
    summary:
      "The default. Roomy and rounded, in the house colours: chalk paper, grape ink and an azure accent.",
    palette: ThemePalette(
      light: seeded(
        ThemeSeeds(
          background: hex("#faf8f4"), foreground: hex("#444054"), accent: azure,
          success: emerald, danger: raspberry, warning: amber),
        .light,
        overrides: chalk.palette.light),
      dark: seeded(
        ThemeSeeds(
          background: hex("#1c1a23"), foreground: hex("#f5f4f7"), accent: azure,
          success: emerald, danger: raspberry, warning: amber),
        .dark,
        overrides: chalk.palette.dark)),
    structure: ThemeStructure(
      radius: ThemeRadiusScale(panel: 12, row: 8, control: 8, pill: 9999, shell: 18),
      border: ThemeBorderScale(hairline: 1, emphasis: 2, focusRing: 2),
      // Half again the editor themes' scale at the top end: the pane gutter
      // (`xl`), the list gutter (`md`) and a row's padding (`xs`) all come
      // from here, so this is what gives the window its air.
      spacing: ThemeSpacingScale(xxs: 2, xs: 6, sm: 10, md: 14, lg: 20, xl: 28),
      typography: ThemeTypography(
        // Bundled on every platform (see `BundledFonts`); the system sans and
        // monospace stand behind them if registration ever fails.
        display: ThemeFontFace(families: ["Inter"], design: .sans),
        body: ThemeFontFace(families: ["Inter"], design: .sans),
        mono: ThemeFontFace(families: ["Geist Mono"], design: .monospaced),
        bodySize: 13,
        scale: ThemeTypeScale(caption: 12, body: 13, title: 16, display: 30, hero: 64),
        microLabel: ThemeMicroLabel(
          size: 11, weight: .semibold, tracking: 0.02, isUppercased: false, role: .mutedText)
      )
    )
  )

  /// A table grown from `seeds`, plus the roles seeds do not reach: the
  /// categorical hues and, in the light table, the media surfaces.
  private static func seeded(
    _ seeds: ThemeSeeds, _ appearance: ThemeAppearance,
    overrides: [ThemeColorRole: ThemeColorValue] = [:]
  ) -> [ThemeColorRole: ThemeColorValue] {
    var table = (seeds.roles(in: appearance) ?? [:]).merging(overrides) { _, override in override }
    table[.categoricalPurple] = purple
    table[.categoricalPink] = pink
    table[.categoricalOrange] = orange
    if appearance == .light {
      table[.mediaLetterbox] = hex("#000000")
      table[.mediaScrim] = hex("#000000").withAlpha(0.7)
      table[.mediaScrimInk] = hex("#ffffff")
    }
    return table
  }

  // MARK: - Zed (née Chalk) — the house style

  /// Flat, bordered, editorial: paper-white surfaces with a bruised-purple
  /// ink, separated by hairlines rather than depth.
  ///
  /// The derived neutrals run warm at the paper end and cool at the ink end,
  /// the way real paper behaves — which is why `altRow` is warmer than `well`
  /// even though both are "a grey".
  public static let chalk = ThemeSpecification(
    identifier: chalkIdentifier,
    name: "Zed",
    summary:
      "The Zed look: IBM Plex Sans and Lilex, square panels, hairlines, warm paper and grape ink.",
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
    name: "Zed Dark",
    summary:
      "The Zed look with the lights off. The same grape hue pulled down, never neutral grey.",
    lockedAppearance: .dark,
    palette: chalk.palette,
    structure: chalk.structure
  )

  // MARK: - Grape — the house design language

  /// Flat, bordered, editorial, and set like a printed timetable: Zed's warm
  /// paper and grape ink, with Arvo — a slab serif — for everything read,
  /// Geist Mono for numerals, code and key caps, the house radius scale
  /// (8 for panels, 6 for anything pressed), and the micro-label as the
  /// signature: 10pt bold capitals tracked 0.15em, in the muted ink.
  ///
  /// Zed shares its colours and dresses them in Zed's own type and square
  /// panels; this is the same palette as the design language states it.
  public static let grape = ThemeSpecification(
    identifier: grapeIdentifier,
    name: "Grape",
    summary:
      "The house style: warm paper, grape ink, Arvo and Geist Mono, hairlines and small capitals.",
    palette: chalk.palette,
    structure: ThemeStructure(
      radius: ThemeRadiusScale(panel: 8, row: 6, control: 6, pill: 9999, shell: 20),
      border: ThemeBorderScale(hairline: 1, emphasis: 2, focusRing: 2),
      spacing: ThemeSpacingScale(xxs: 2, xs: 4, sm: 8, md: 12, lg: 16, xl: 24),
      typography: ThemeTypography(
        // The serif body against flat paper is most of the character, so the
        // fallback is a serif too: if Arvo ever fails to register, New York
        // stands in rather than a sans that would read as a different theme.
        display: ThemeFontFace(families: ["Arvo"], design: .serif),
        body: ThemeFontFace(families: ["Arvo"], design: .serif),
        mono: ThemeFontFace(families: ["Geist Mono"], design: .monospaced),
        bodySize: 13,
        scale: ThemeTypeScale(caption: 11, body: 13, title: 16, display: 28, hero: 64),
        microLabel: ThemeMicroLabel(
          size: 10, weight: .bold, tracking: 0.15, isUppercased: true, role: .mutedText)
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
