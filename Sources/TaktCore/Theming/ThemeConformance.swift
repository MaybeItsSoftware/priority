import Foundation
import TaktRustCore

/// The resolution cases in `shared/themes/conformance/`, and the canonical
/// form a resolved theme is written in there.
///
/// The resolver is the Rust core's (`core/src/theme`), which every client
/// calls. These cases are written from it, its own tests hold
/// `shared/themes/` to it, and so do this module's and Android's. The format
/// is documented in `shared/themes/README.md`.
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
      let resolved = themeResolved(specification: specification.core, requested: requested.core)
      identifier = resolved.identifier
      name = resolved.name
      lockedAppearance = resolved.lockedAppearance.map { ThemeAppearance($0).rawValue }
      appearance = ThemeAppearance(resolved.appearance).rawValue
      colors = resolved.colors
      structure = Structure(ThemeStructure(resolved.structure))
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

    /// The case as the core resolves it: `files` loaded together for every
    /// platform, `selected` picked, both appearances drawn.
    public init(files: [File], selected: String) {
      let text = ThemeConformance.text(files: files, selected: selected)
      // The core writes exactly this shape; failing to read it back is a bug
      // in the bindings, not in a theme.
      // swiftlint:disable:next force_try
      self = try! JSONDecoder().decode(Case.self, from: Data(text.utf8))
    }

    /// Pretty-printed with sorted keys and a trailing newline: the bytes the
    /// shared files hold.
    public func encoded() throws -> Data {
      Data(ThemeConformance.text(files: files, selected: selected).utf8)
    }
  }

  /// What a device shows for the theme `identifier`: the user theme of that
  /// name if it loaded, else the built-in, else the default standing in.
  public static func selected(
    _ identifier: String, in library: ThemeFileLibrary, for platform: ThemePlatform
  ) -> ThemeSpecification {
    library.themes.first { $0.identifier == identifier }
      ?? BuiltInThemeSpecifications.specification(withIdentifier: identifier, for: platform)
      ?? BuiltInThemeSpecifications.defaultTheme(for: platform)
  }

  /// A built-in as the complete file `shared/themes/` holds: every colour and
  /// structural value, the Mac's structure as `structure` and the phones'
  /// differences under `platforms`. It extends nothing, so a reader needs no
  /// other file to resolve it.
  public static func sharedFile(for builtIn: ThemeSpecification) -> ThemeFile {
    themeSharedFile(identifier: builtIn.identifier).map(ThemeFile.init)
      ?? ThemeFile(specification: builtIn)
  }

  /// `shared/themes/<name>.json` → the bytes it should hold, for each
  /// built-in.
  public static func sharedFiles() throws -> [String: Data] {
    Dictionary(uniqueKeysWithValues: themeSharedFiles().map { ($0.name, Data($0.json.utf8)) })
  }

  /// The stem a built-in's shared file goes under. Zed keeps its old
  /// name, Chalk, here as in its identifier.
  public static func sharedFileName(for identifier: String) -> String {
    switch identifier {
    case BuiltInThemeSpecifications.chalkIdentifier: return "chalk"
    case BuiltInThemeSpecifications.chalkDarkIdentifier: return "chalk-dark"
    case BuiltInThemeSpecifications.grapeIdentifier: return "grape"
    default: return "priority"
    }
  }

  /// A case's bytes, as the core writes them.
  static func text(files: [File], selected: String) -> String {
    themeConformanceCase(
      files: files.map { CoreThemeNamedText(name: $0.name, json: $0.json) }, selected: selected)
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
