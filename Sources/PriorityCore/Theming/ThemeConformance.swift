import Foundation

/// The resolution cases in `shared/themes/conformance/`, and the canonical
/// form a resolved theme is written in there.
///
/// Swift is the reference resolver. These cases are written from it, and the
/// Kotlin resolver on Android (and anything else that reads theme files) has
/// to reproduce them exactly. The format is documented in
/// `shared/themes/README.md`.
public enum ThemeConformance {
  /// One input file, as text: a case may hold a file that is not valid JSON.
  public struct File: Codable, Equatable, Sendable {
    public var name: String
    public var json: String

    public init(name: String, json: String) {
      self.name = name
      self.json = json
    }
  }

  /// A theme fully resolved for one platform and one requested appearance.
  public struct Resolved: Codable, Equatable, Sendable {
    public var identifier: String
    public var name: String
    /// `"light"`, `"dark"` or `nil`.
    public var lockedAppearance: String?
    /// The appearance actually drawn: the lock if there is one, else the
    /// appearance asked for.
    public var appearance: String
    /// Every role, as lowercase `#rrggbb` or `#rrggbbaa`, resolved in
    /// `appearance` (so invariant roles come from the light table, and a role
    /// missing from one table is borrowed from the other).
    public var colors: [String: String]
    public var structure: Structure

    public init(_ specification: ThemeSpecification, requested: ThemeAppearance) {
      let drawn = specification.lockedAppearance ?? requested
      identifier = specification.identifier
      name = specification.name
      lockedAppearance = specification.lockedAppearance?.rawValue
      appearance = drawn.rawValue
      colors = Dictionary(
        uniqueKeysWithValues: ThemeColorRole.allCases.map {
          ($0.rawValue, specification.color($0, in: drawn).hexString.lowercased())
        })
      structure = Structure(specification.structure)
    }

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: ResolvedCodingKeys.self)
      try container.encode(identifier, forKey: .identifier)
      try container.encode(name, forKey: .name)
      // Always present, so `null` is stated rather than implied.
      try container.encode(lockedAppearance, forKey: .lockedAppearance)
      try container.encode(appearance, forKey: .appearance)
      try container.encode(colors, forKey: .colors)
      try container.encode(structure, forKey: .structure)
    }
  }

  // The parts of a resolved structure, kept one level down for the linter.
  public struct Face: Codable, Equatable, Sendable {
    public var families: [String]
    public var design: String
  }
  public struct MicroLabel: Codable, Equatable, Sendable {
    public var size: Double
    public var weight: String
    public var tracking: Double
    public var uppercase: Bool
    public var role: String
  }
  public struct Typography: Codable, Equatable, Sendable {
    public var display: Face
    public var body: Face
    public var mono: Face
    public var bodySize: Double
    public var scale: [String: Double]
    public var microLabel: MicroLabel
  }

  /// Every structural value, stated. The same shape as a theme file's
  /// `structure`, with nothing optional.
  public struct Structure: Codable, Equatable, Sendable {
    public var radius: [String: Double]
    public var border: [String: Double]
    public var spacing: [String: Double]
    public var typography: Typography
    public var touchTarget: Double
    public var usesShadows: Bool
    public var usesGradientsOnChrome: Bool

    public init(_ structure: ThemeStructure) {
      func face(_ face: ThemeFontFace) -> Face {
        Face(families: face.families, design: face.design.rawValue)
      }
      let type = structure.typography
      radius = [
        "panel": structure.radius.panel, "row": structure.radius.row,
        "control": structure.radius.control, "pill": structure.radius.pill,
        "shell": structure.radius.shell,
      ]
      border = [
        "hairline": structure.border.hairline, "emphasis": structure.border.emphasis,
        "focusRing": structure.border.focusRing,
      ]
      spacing = [
        "xxs": structure.spacing.xxs, "xs": structure.spacing.xs, "sm": structure.spacing.sm,
        "md": structure.spacing.md, "lg": structure.spacing.lg, "xl": structure.spacing.xl,
      ]
      typography = Typography(
        display: face(type.display), body: face(type.body), mono: face(type.mono),
        bodySize: type.bodySize,
        scale: [
          "caption": type.scale.caption, "body": type.scale.body, "title": type.scale.title,
          "display": type.scale.display, "hero": type.scale.hero,
        ],
        microLabel: MicroLabel(
          size: type.microLabel.size, weight: type.microLabel.weight.rawValue,
          tracking: type.microLabel.tracking, uppercase: type.microLabel.isUppercased,
          role: type.microLabel.role.rawValue))
      touchTarget = structure.touchTarget
      usesShadows = structure.usesShadows
      usesGradientsOnChrome = structure.usesGradientsOnChrome
    }
  }

  /// One reported problem. `message` is the reference wording; a port is
  /// held to `source` and `severity`, in order.
  public struct Issue: Codable, Equatable, Sendable {
    public var source: String
    public var severity: String
    public var message: String
  }

  /// A whole case: the inputs, the theme picked, and what every platform
  /// shows in each appearance.
  public struct Case: Codable, Equatable, Sendable {
    public var files: [File]
    public var selected: String
    /// Platform → requested appearance → resolved theme.
    public var expected: [String: [String: Resolved]]
    /// What loading the files reports, in order, without the audit.
    public var issues: [Issue]

    public init(files: [File], selected: String) {
      self.files = files
      self.selected = selected
      let sources = files.map { ThemeFileSource(name: $0.name, data: Data($0.json.utf8)) }
      var expected: [String: [String: Resolved]] = [:]
      var issues: [Issue] = []
      for platform in ThemePlatform.allCases {
        let library = ThemeFileLoader.load(sources, platform: platform)
        let theme = ThemeConformance.selected(selected, in: library, for: platform)
        expected[platform.rawValue] = Dictionary(
          uniqueKeysWithValues: ThemeAppearance.allCases.map {
            ($0.rawValue, Resolved(theme, requested: $0))
          })
        // Only the audit differs by platform, so the rest is the same three
        // times over; it is kept once, in the order the Mac reports it.
        if platform == .macos {
          issues = library.issues.filter { !$0.isAudit }.map {
            Issue(source: $0.source, severity: $0.severity.name, message: $0.message)
          }
        }
      }
      self.expected = expected
      self.issues = issues
    }

    /// Pretty-printed with sorted keys and a trailing newline: the bytes the
    /// shared files hold.
    public func encoded() throws -> Data {
      try ThemeConformance.encode(self)
    }
  }

  /// What a device shows for the theme `identifier`: the user theme of that
  /// name if it loaded, else the built-in, else Chalk standing in.
  public static func selected(
    _ identifier: String, in library: ThemeFileLibrary, for platform: ThemePlatform
  ) -> ThemeSpecification {
    library.themes.first { $0.identifier == identifier }
      ?? BuiltInThemeSpecifications.specification(withIdentifier: identifier, for: platform)
      ?? BuiltInThemeSpecifications.chalk(for: platform)
  }

  /// A built-in as the complete file `shared/themes/` holds: every colour and
  /// structural value, the Mac's structure as `structure` and the phones'
  /// differences under `platforms`. It extends nothing, so a reader needs no
  /// other file to resolve it.
  public static func sharedFile(for builtIn: ThemeSpecification) -> ThemeFile {
    var variants: [ThemePlatform: ThemeSpecification] = [:]
    for platform in ThemePlatform.allCases {
      variants[platform] = BuiltInThemeSpecifications.specification(
        withIdentifier: builtIn.identifier, for: platform)
    }
    let mac = variants[.macos] ?? builtIn
    var file = ThemeFile(specification: mac, platformVariants: variants)
    file.extends = .nothing
    return file
  }

  /// `shared/themes/<name>.json` → the bytes it should hold, for each
  /// built-in.
  public static func sharedFiles() throws -> [String: Data] {
    var files: [String: Data] = [:]
    for builtIn in BuiltInThemeSpecifications.all {
      let name =
        builtIn.identifier == BuiltInThemeSpecifications.chalkIdentifier ? "chalk" : "chalk-dark"
      files["\(name).json"] = try encode(sharedFile(for: builtIn))
    }
    return files
  }

  static func encode(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value) + Data("\n".utf8)
  }
}

extension ThemeIssueSeverity {
  /// `error`, `warning` or `note`.
  public var name: String {
    switch self {
    case .error: return "error"
    case .warning: return "warning"
    case .note: return "note"
    }
  }
}

/// `ThemeConformance.Resolved`'s keys, at file scope only because the linter
/// limits nesting.
private enum ResolvedCodingKeys: String, CodingKey {
  case identifier, name, lockedAppearance, appearance, colors, structure
}
