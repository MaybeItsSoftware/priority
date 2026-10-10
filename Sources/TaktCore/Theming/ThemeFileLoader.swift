import Foundation
import TaktRustCore

/// Something a theme file got wrong, in a sentence someone editing it can act
/// on. Never fatal: a bad value is skipped and the value it would have
/// replaced stays; only a theme that cannot paint every role is dropped.
public struct ThemeFileIssue: Equatable, Sendable, CustomStringConvertible {
  /// The file name, e.g. `dusk.json`.
  public let source: String
  public let severity: ThemeIssueSeverity
  public let message: String
  /// True for a finding of the `validate()` audit of the theme the file
  /// produced (contrast, the radius scale), as opposed to a problem with what
  /// the file says. Audit findings depend on the platform the theme was
  /// resolved for; the rest do not.
  public let isAudit: Bool

  public init(source: String, severity: ThemeIssueSeverity, message: String, isAudit: Bool = false) {
    self.source = source
    self.severity = severity
    self.message = message
    self.isAudit = isAudit
  }

  public var description: String { "\(source): \(message)" }
}

/// One file's raw bytes, named.
public struct ThemeFileSource: Equatable, Sendable {
  public let name: String
  public let data: Data

  public init(name: String, data: Data) {
    self.name = name
    self.data = data
  }
}

/// What became of one file.
public struct ThemeFileOutcome: Equatable, Sendable {
  public let source: String
  /// `nil` when the theme was skipped; `skippedReason` says why.
  public let specification: ThemeSpecification?
  public let skippedReason: String?
  /// Everything reported about this file, worst first — including the
  /// `validate()` audit of the theme it produced.
  public let issues: [ThemeFileIssue]

  public init(
    source: String, specification: ThemeSpecification?, skippedReason: String?,
    issues: [ThemeFileIssue]
  ) {
    self.source = source
    self.specification = specification
    self.skippedReason = skippedReason
    self.issues = issues
  }
}

/// A folder of theme files, loaded.
public struct ThemeFileLibrary: Equatable, Sendable {
  /// One per file, in file-name order.
  public let outcomes: [ThemeFileOutcome]

  public init(outcomes: [ThemeFileOutcome]) {
    self.outcomes = outcomes
  }

  public static let empty = ThemeFileLibrary(outcomes: [])

  /// The themes that loaded, in file-name order.
  public var themes: [ThemeSpecification] { outcomes.compactMap(\.specification) }

  public var issues: [ThemeFileIssue] { outcomes.flatMap(\.issues) }
}

/// Turns theme files into `ThemeSpecification`s: decodes, follows `extends`,
/// merges, and audits. The work is the Rust core's (`core/src/theme`), which
/// Android calls too; this is its Swift face, one call per folder or file.
public enum ThemeFileLoader {
  /// The extension a theme file has to carry to be read.
  public static let fileExtension = "json"

  /// A user theme with no `identifier` is named after its file, under this
  /// prefix, so it cannot collide with a built-in.
  public static let derivedIdentifierPrefix = "user."

  /// Decodes one file. A document that is not a theme at all is `nil` plus
  /// the reason; keys the format does not have are reported as warnings,
  /// because a misspelt key is otherwise a silent no-op.
  public static func decode(_ data: Data, source: String) -> (ThemeFile?, [ThemeFileIssue]) {
    let decoded = themeDecode(data: data, source: source)
    return (decoded.file.map(ThemeFile.init), decoded.issues.map(ThemeFileIssue.init))
  }

  /// Loads every source for `platform`, resolving `extends` against
  /// `builtIns` and against each other. Sources are taken in name order; an
  /// identifier that is already a built-in, or already taken by an earlier
  /// file, is skipped.
  ///
  /// `builtIns` and `defaultBase` default to the built-in themes as resolved
  /// for `platform`. Each theme's structure is, latest winning: the theme it
  /// extends (resolved for this platform), its own `structure`, then its
  /// `platforms.<platform>.structure`.
  public static func load(
    _ sources: [ThemeFileSource],
    platform: ThemePlatform = .macos,
    builtIns: [ThemeSpecification]? = nil,
    defaultBase: ThemeSpecification? = nil
  ) -> ThemeFileLibrary {
    let outcomes = themeLoad(
      sources: sources.map { CoreThemeFileSource(name: $0.name, data: $0.data) }, platform: platform.core,
      builtIns: builtIns?.map(\.core), defaultBase: defaultBase?.core)
    return ThemeFileLibrary(outcomes: outcomes.map(ThemeFileOutcome.init))
  }

  /// Resolves one already-decoded file against a base — `nil` for a file that
  /// inherits no colours. The single-file path, for tests and tooling.
  public static func resolve(
    _ file: ThemeFile, source: String, base: ThemeSpecification?, platform: ThemePlatform = .macos
  ) -> ThemeFileOutcome {
    ThemeFileOutcome(themeResolve(file: file.core, source: source, base: base?.core, platform: platform.core))
  }

  /// Lays a partial structure over a whole one, the way a theme file's
  /// `structure` is laid over the theme it extends. Problems go to `report`
  /// with `path` (e.g. `structure`) in front of each key.
  public static func merge(
    _ overrides: ThemeFile.Structure?, over base: ThemeStructure, path: String = "structure",
    report: (ThemeIssueSeverity, String) -> Void = { _, _ in }
  ) -> ThemeStructure {
    guard let overrides else { return base }
    let merged = themeMergeStructure(overrides: overrides.core, base: base.core, path: path)
    for entry in merged.reports { report(ThemeIssueSeverity(entry.severity), entry.message) }
    return ThemeStructure(merged.structure)
  }

  /// The file's own identifier, or one derived from its name.
  public static func identifier(of file: ThemeFile, source: String) -> String {
    themeIdentifier(file: file.core, source: source)
  }

  /// `dusk.json` → `dusk`.
  public static func stem(of source: String) -> String {
    let suffix = "." + fileExtension
    return source.hasSuffix(suffix) ? String(source.dropLast(suffix.count)) : source
  }
}
