import Foundation

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
/// merges, and audits.
public enum ThemeFileLoader {
  /// The extension a theme file has to carry to be read.
  public static let fileExtension = "json"

  /// A user theme with no `identifier` is named after its file, under this
  /// prefix, so it cannot collide with a built-in.
  public static let derivedIdentifierPrefix = "user."

  // MARK: - Decoding

  /// Decodes one file. A document that is not a theme at all is `nil` plus
  /// the reason; keys the format does not have are reported as warnings,
  /// because a misspelt key is otherwise a silent no-op.
  public static func decode(_ data: Data, source: String) -> (ThemeFile?, [ThemeFileIssue]) {
    let file: ThemeFile
    do {
      file = try JSONDecoder().decode(ThemeFile.self, from: data)
    } catch {
      return (nil, [.init(source: source, severity: .error, message: reason(error))])
    }
    let unknown = ThemeFileSchema.unknownKeys(in: data).map { path in
      ThemeFileIssue(
        source: source, severity: .warning,
        message: ThemeFileSchema.isPlatformPalette(path)
          ? "\(path) is not allowed: colour is the same on every platform; ignored"
          : "\(path) is not a theme setting; ignored")
    }
    return (file, unknown)
  }

  // MARK: - Loading a folder

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
    let builtIns = builtIns ?? BuiltInThemeSpecifications.all(for: platform)
    let defaultBase = defaultBase ?? BuiltInThemeSpecifications.defaultTheme(for: platform)
    let ordered = sources.sorted { $0.name < $1.name }
    let builtInsByIdentifier = Dictionary(
      builtIns.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })

    var outcomes: [String: ThemeFileOutcome] = [:]
    var candidates: [String: (source: String, file: ThemeFile, issues: [ThemeFileIssue])] = [:]

    for source in ordered {
      let (decoded, issues) = decode(source.data, source: source.name)
      guard let file = decoded else {
        outcomes[source.name] = skipped(source.name, "could not be read", issues)
        continue
      }
      let identifier = identifier(of: file, source: source.name)
      if builtInsByIdentifier[identifier] != nil {
        outcomes[source.name] = skipped(
          source.name, "identifier \"\(identifier)\" is a built-in theme's; give it one of its own",
          issues)
      } else if let earlier = candidates[identifier] {
        outcomes[source.name] = skipped(
          source.name, "identifier \"\(identifier)\" is already used by \(earlier.source)", issues)
      } else {
        candidates[identifier] = (source.name, file, issues)
      }
    }

    // Resolve depth-first so a theme can extend another user theme regardless
    // of file order. `resolved` memoises by identifier; `inProgress` catches a
    // cycle.
    var resolved: [String: ThemeSpecification?] = [:]
    var inProgress: Set<String> = []

    func resolve(_ identifier: String) -> ThemeSpecification? {
      if let done = resolved[identifier] { return done }
      guard let candidate = candidates[identifier] else { return nil }
      guard !inProgress.contains(identifier) else {
        let outcome = skipped(
          candidate.source, "its extends chain comes back round to itself", candidate.issues)
        outcomes[candidate.source] = outcome
        resolved[identifier] = .some(nil)
        return nil
      }
      inProgress.insert(identifier)
      defer { inProgress.remove(identifier) }

      let base: ThemeSpecification?
      switch candidate.file.extends {
      case .defaultTheme:
        base = defaultBase
      case .nothing:
        base = nil
      case .theme(let parent):
        if let builtIn = builtInsByIdentifier[parent] {
          base = builtIn
        } else if candidates[parent] != nil {
          guard let parentSpecification = resolve(parent) else {
            // A cycle may already have recorded this file's own outcome.
            if resolved[identifier] == nil {
              outcomes[candidate.source] = skipped(
                candidate.source, "it extends \"\(parent)\", which did not load", candidate.issues)
              resolved[identifier] = .some(nil)
            }
            return nil
          }
          base = parentSpecification
        } else {
          outcomes[candidate.source] = skipped(
            candidate.source, "it extends \"\(parent)\", which is not a theme", candidate.issues)
          resolved[identifier] = .some(nil)
          return nil
        }
      }
      if let done = resolved[identifier] { return done }  // Settled by a cycle below us.

      let outcome = ThemeFileMerger.merge(
        candidate.file, identifier: identifier, source: candidate.source, base: base,
        structureFallback: defaultBase.structure, platform: platform)
      outcomes[candidate.source] = ThemeFileOutcome(
        source: outcome.source, specification: outcome.specification,
        skippedReason: outcome.skippedReason, issues: sorted(candidate.issues + outcome.issues))
      resolved[identifier] = .some(outcome.specification)
      return outcome.specification
    }

    for identifier in candidates.keys.sorted() { _ = resolve(identifier) }

    return ThemeFileLibrary(outcomes: ordered.compactMap { outcomes[$0.name] })
  }

  /// Resolves one already-decoded file against a base — `nil` for a file that
  /// inherits no colours. The single-file path, for tests and tooling.
  public static func resolve(
    _ file: ThemeFile, source: String, base: ThemeSpecification?, platform: ThemePlatform = .macos
  ) -> ThemeFileOutcome {
    ThemeFileMerger.merge(
      file, identifier: identifier(of: file, source: source), source: source, base: base,
      structureFallback: BuiltInThemeSpecifications.defaultTheme(for: platform).structure,
      platform: platform)
  }

  /// Lays a partial structure over a whole one, the way a theme file's
  /// `structure` is laid over the theme it extends. Problems go to `report`
  /// with `path` (e.g. `structure`) in front of each key.
  public static func merge(
    _ overrides: ThemeFile.Structure?, over base: ThemeStructure, path: String = "structure",
    report: (ThemeIssueSeverity, String) -> Void = { _, _ in }
  ) -> ThemeStructure {
    ThemeFileMerger.mergeStructure(overrides, over: base, prefix: path, report: report)
  }

  /// The file's own identifier, or one derived from its name.
  public static func identifier(of file: ThemeFile, source: String) -> String {
    if let stated = file.identifier?.trimmingCharacters(in: .whitespacesAndNewlines), !stated.isEmpty {
      return stated
    }
    return derivedIdentifierPrefix + stem(of: source)
  }

  /// `dusk.json` → `dusk`.
  public static func stem(of source: String) -> String {
    let suffix = "." + fileExtension
    return source.hasSuffix(suffix) ? String(source.dropLast(suffix.count)) : source
  }

  // MARK: - Helpers

  private static func skipped(
    _ source: String, _ reason: String, _ issues: [ThemeFileIssue]
  ) -> ThemeFileOutcome {
    ThemeFileOutcome(
      source: source, specification: nil, skippedReason: reason,
      issues: sorted([.init(source: source, severity: .error, message: "not loaded: \(reason)")] + issues))
  }

  static func sorted(_ issues: [ThemeFileIssue]) -> [ThemeFileIssue] {
    // Stable: `sorted` is not guaranteed stable, so rank by index as well.
    issues.enumerated()
      .sorted { lhs, rhs in
        lhs.element.severity.rank != rhs.element.severity.rank
          ? lhs.element.severity.rank > rhs.element.severity.rank
          : lhs.offset < rhs.offset
      }
      .map(\.element)
  }

  private static func reason(_ error: any Error) -> String {
    guard let decoding = error as? DecodingError else {
      return "not a theme file: \(error.localizedDescription)"
    }
    func path(_ context: DecodingError.Context) -> String {
      let joined = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }
        .joined(separator: ".")
      return joined.isEmpty ? "the file" : joined
    }
    switch decoding {
    case .dataCorrupted(let context):
      if context.codingPath.isEmpty { return "not valid JSON" }
      return "\(path(context)) could not be read"
    case .typeMismatch(let type, let context):
      return "\(path(context)) should be \(describe(type))"
    case .valueNotFound(let type, let context):
      return "\(path(context)) should be \(describe(type)), not null"
    case .keyNotFound(let key, _):
      return "\(key.stringValue) is missing"
    @unknown default:
      return "not a theme file"
    }
  }

  private static func describe(_ type: Any.Type) -> String {
    switch type {
    case is Double.Type: return "a number"
    case is String.Type: return "a string"
    case is Bool.Type: return "true or false"
    case is [String].Type: return "a list of strings"
    default: return "an object"
    }
  }
}

// MARK: - Merging

/// Lays one file over its base. Each bad value is one issue and leaves the
/// base's value standing.
enum ThemeFileMerger {
  static func merge(
    _ file: ThemeFile,
    identifier: String,
    source: String,
    base: ThemeSpecification?,
    structureFallback: ThemeStructure,
    platform: ThemePlatform
  ) -> ThemeFileOutcome {
    var issues: [ThemeFileIssue] = []
    func report(_ severity: ThemeIssueSeverity, _ message: String) {
      issues.append(.init(source: source, severity: severity, message: message))
    }

    // Seeds, then palette: the base's table, the roles grown from the
    // seeds this file gives for the appearance (over the seeds the base
    // implies), then the roles the file states outright.
    func seeded(
      _ appearance: ThemeAppearance, _ table: [ThemeColorRole: ThemeColorValue]
    ) -> [ThemeColorRole: ThemeColorValue] {
      guard let raw = file.seeds?[appearance] else { return table }
      var stated = ThemeSeeds()
      for key in raw.keys.sorted() {
        let value = raw[key] ?? ""
        guard let seed = ThemeSeeds.Key(rawValue: key) else {
          report(
            .warning,
            "seeds.\(appearance.rawValue).\(key) is not a seed (background, foreground, accent, success, danger or warning); ignored")
          continue
        }
        guard let color = ThemeColorValue(hex: value) else {
          report(
            .error,
            "seeds.\(appearance.rawValue).\(key) \"\(value)\" is not a hex colour (#rgb, #rrggbb or #rrggbbaa)")
          continue
        }
        stated[seed] = color
      }
      let seeds = ThemeSeeds(implicitIn: table).overlaid(with: stated)
      guard let roles = seeds.roles(in: appearance) else {
        report(.error, "seeds.\(appearance.rawValue) needs a background and a foreground; ignored")
        return table
      }
      return table.merging(roles) { _, derived in derived }
    }

    // Palette.
    func table(
      _ appearance: ThemeAppearance, _ overrides: [String: String]?
    ) -> [ThemeColorRole: ThemeColorValue] {
      var table = seeded(appearance, base?.palette.table(appearance) ?? [:])
      for key in (overrides ?? [:]).keys.sorted() {
        let raw = overrides?[key] ?? ""
        guard let role = ThemeColorRole(rawValue: key) else {
          report(.warning, "palette.\(appearance.rawValue).\(key) is not a colour role; ignored")
          continue
        }
        guard let value = ThemeColorValue(hex: raw) else {
          report(
            .error,
            "palette.\(appearance.rawValue).\(key) \"\(raw)\" is not a hex colour (#rgb, #rrggbb or #rrggbbaa)")
          continue
        }
        table[role] = value
      }
      return table
    }
    let palette = ThemePalette(
      light: table(.light, file.palette?.light), dark: table(.dark, file.palette?.dark))

    // A role in neither table would paint magenta; that is the one thing that
    // stops a theme loading.
    let unpainted = ThemeColorRole.allCases.filter {
      palette.light[$0] == nil && palette.dark[$0] == nil
    }
    if !unpainted.isEmpty {
      let names = unpainted.map(\.rawValue).joined(separator: ", ")
      let reason = "no colour for \(names)"
      return ThemeFileOutcome(
        source: source, specification: nil, skippedReason: reason,
        issues: ThemeFileLoader.sorted(
          [.init(source: source, severity: .error, message: "not loaded: \(reason)")] + issues))
    }

    // Appearance lock.
    var lockedAppearance = base?.lockedAppearance
    switch file.lockedAppearance {
    case .inherit: break
    case .unlocked: lockedAppearance = nil
    case .locked(let raw):
      if let appearance = ThemeAppearance(rawValue: raw) {
        lockedAppearance = appearance
      } else {
        report(.error, "lockedAppearance \"\(raw)\" should be \"light\", \"dark\" or null")
      }
    }

    // Structure: the base as resolved for this platform, then the file's own
    // structure, then its entry for this platform. Every platform's entry is
    // checked, so a bad value for the phone is reported on the Mac too, but
    // only this platform's is used.
    var structure = mergeStructure(
      file.structure, over: base?.structure ?? structureFallback, prefix: "structure", report: report)
    for candidate in ThemePlatform.allCases {
      guard let entry = file.platforms?[candidate]?.structure else { continue }
      let merged = mergeStructure(
        entry, over: structure, prefix: "platforms.\(candidate.rawValue).structure",
        report: report)
      if candidate == platform { structure = merged }
    }

    let specification = ThemeSpecification(
      identifier: identifier,
      name: nonEmpty(file.name) ?? ThemeFileLoader.stem(of: source),
      summary: nonEmpty(file.summary) ?? "Your theme, from \(source).",
      lockedAppearance: lockedAppearance,
      palette: palette,
      structure: structure
    )
    for finding in specification.validate() {
      // A missing role is a fact about the file; the rest is the audit.
      var isAudit = true
      if case .missingRole = finding { isAudit = false }
      issues.append(
        .init(source: source, severity: finding.severity, message: finding.message, isAudit: isAudit))
    }
    return ThemeFileOutcome(
      source: source, specification: specification, skippedReason: nil,
      issues: ThemeFileLoader.sorted(issues))
  }

  // MARK: Structure

  typealias Report = (ThemeIssueSeverity, String) -> Void

  static func mergeStructure(
    _ overrides: ThemeFile.Structure?, over base: ThemeStructure, prefix: String, report: Report
  ) -> ThemeStructure {
    guard let overrides else { return base }

    func length(_ value: Double?, _ fallback: Double, _ path: String, positive: Bool = false) -> Double {
      guard let value else { return fallback }
      guard value.isFinite, positive ? value > 0 : value >= 0 else {
        report(.error, "\(prefix).\(path) \(number(value)) should be \(positive ? "above zero" : "zero or more")")
        return fallback
      }
      return value
    }

    let radius = overrides.radius.map { file in
      ThemeRadiusScale(
        panel: length(file.panel, base.radius.panel, "radius.panel"),
        row: length(file.row, base.radius.row, "radius.row"),
        control: length(file.control, base.radius.control, "radius.control"),
        pill: length(file.pill, base.radius.pill, "radius.pill"),
        shell: length(file.shell, base.radius.shell, "radius.shell"))
    } ?? base.radius

    let border = overrides.border.map { file in
      ThemeBorderScale(
        hairline: length(file.hairline, base.border.hairline, "border.hairline"),
        emphasis: length(file.emphasis, base.border.emphasis, "border.emphasis"),
        focusRing: length(file.focusRing, base.border.focusRing, "border.focusRing"))
    } ?? base.border

    let spacing = overrides.spacing.map { file in
      ThemeSpacingScale(
        xxs: length(file.xxs, base.spacing.xxs, "spacing.xxs"),
        xs: length(file.xs, base.spacing.xs, "spacing.xs"),
        sm: length(file.sm, base.spacing.sm, "spacing.sm"),
        md: length(file.md, base.spacing.md, "spacing.md"),
        lg: length(file.lg, base.spacing.lg, "spacing.lg"),
        xl: length(file.xl, base.spacing.xl, "spacing.xl"))
    } ?? base.spacing

    let typography = overrides.typography.map {
      mergeTypography($0, over: base.typography, prefix: prefix, length: length, report: report)
    } ?? base.typography

    return ThemeStructure(
      radius: radius,
      border: border,
      spacing: spacing,
      typography: typography,
      touchTarget: length(overrides.touchTarget, base.touchTarget, "touchTarget"),
      usesShadows: overrides.usesShadows ?? base.usesShadows,
      usesGradientsOnChrome: overrides.usesGradientsOnChrome ?? base.usesGradientsOnChrome)
  }

  private static func mergeTypography(
    _ file: ThemeFile.Typography,
    over base: ThemeTypography,
    prefix: String,
    length: (Double?, Double, String, Bool) -> Double,
    report: Report
  ) -> ThemeTypography {
    func face(_ file: ThemeFile.Face?, _ base: ThemeFontFace, _ path: String) -> ThemeFontFace {
      guard let file else { return base }
      var design = base.design
      if let raw = file.design {
        if let parsed = ThemeFontDesign(rawValue: raw) {
          design = parsed
        } else {
          report(
            .error,
            "\(prefix).typography.\(path).design \"\(raw)\" should be serif, sans, monospaced or rounded")
        }
      }
      return ThemeFontFace(families: file.families ?? base.families, design: design)
    }

    let bodySize = length(file.bodySize, base.bodySize, "typography.bodySize", true)
    // A new body size with no scale re-proportions the scale from it, so
    // "make everything bigger" is one number. Stated steps still win.
    let scaleBase =
      file.bodySize != nil && bodySize != base.bodySize
      ? ThemeTypeScale.proportioned(fromBody: bodySize) : base.scale
    let scale = file.scale.map { steps in
      ThemeTypeScale(
        caption: length(steps.caption, scaleBase.caption, "typography.scale.caption", true),
        body: length(steps.body, scaleBase.body, "typography.scale.body", true),
        title: length(steps.title, scaleBase.title, "typography.scale.title", true),
        display: length(steps.display, scaleBase.display, "typography.scale.display", true),
        hero: length(steps.hero, scaleBase.hero, "typography.scale.hero", true))
    } ?? scaleBase

    let microLabel = file.microLabel.map { label in
      var weight = base.microLabel.weight
      if let raw = label.weight {
        if let parsed = ThemeFontWeight(rawValue: raw) {
          weight = parsed
        } else {
          report(
            .error,
            "\(prefix).typography.microLabel.weight \"\(raw)\" should be regular, medium, semibold, bold or black")
        }
      }
      var role = base.microLabel.role
      if let raw = label.role {
        if let parsed = ThemeColorRole(rawValue: raw) {
          role = parsed
        } else {
          report(.error, "\(prefix).typography.microLabel.role \"\(raw)\" is not a colour role")
        }
      }
      return ThemeMicroLabel(
        size: length(label.size, base.microLabel.size, "typography.microLabel.size", true),
        weight: weight,
        tracking: length(label.tracking, base.microLabel.tracking, "typography.microLabel.tracking", false),
        isUppercased: label.uppercase ?? base.microLabel.isUppercased,
        role: role)
    } ?? base.microLabel

    return ThemeTypography(
      display: face(file.display, base.display, "display"),
      body: face(file.body, base.body, "body"),
      mono: face(file.mono, base.mono, "mono"),
      bodySize: bodySize,
      scale: scale,
      microLabel: microLabel)
  }

  /// `-2` rather than `-2.0`, so a message reads the way the file was
  /// written — and the same on every platform that reproduces it.
  static func number(_ value: Double) -> String {
    value.isFinite && value == value.rounded() && abs(value) < 1e15
      ? String(Int64(value)) : String(value)
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed
  }
}

// MARK: - Unknown keys

/// The shape of the format, for reporting keys it does not have. Codable
/// ignores an unknown key, which turns a typo like `"pallete"` into a silent
/// no-op; this turns it into a warning.
enum ThemeFileSchema {
  indirect enum Node {
    /// An object with exactly these keys.
    case object([String: Node])
    /// Anything goes below here — a value, or a map checked elsewhere.
    case any
  }

  static let root: Node = {
    let face: Node = .object(["families": .any, "design": .any])
    let structure: Node = .object([
      "radius": .object(["panel": .any, "row": .any, "control": .any, "pill": .any, "shell": .any]),
      "border": .object(["hairline": .any, "emphasis": .any, "focusRing": .any]),
      "spacing": .object([
        "xxs": .any, "xs": .any, "sm": .any, "md": .any, "lg": .any, "xl": .any,
      ]),
      "typography": .object([
        "display": face, "body": face, "mono": face, "bodySize": .any,
        "scale": .object([
          "caption": .any, "body": .any, "title": .any, "display": .any, "hero": .any,
        ]),
        "microLabel": .object([
          "size": .any, "weight": .any, "tracking": .any, "uppercase": .any, "role": .any,
        ]),
      ]),
      "touchTarget": .any, "usesShadows": .any, "usesGradientsOnChrome": .any,
    ])
    // A platform's entry is structure only. `palette` is left out on purpose,
    // so one there is reported (and Codable never reads it).
    let platform: Node = .object(["structure": structure])
    return .object([
      "identifier": .any, "name": .any, "summary": .any, "lockedAppearance": .any, "extends": .any,
      // Role names are checked by the merger, which can say which role.
      "palette": .object(["light": .any, "dark": .any]),
      // So are seed names.
      "seeds": .object(["light": .any, "dark": .any]),
      "structure": structure,
      "platforms": .object(
        Dictionary(uniqueKeysWithValues: ThemePlatform.allCases.map { ($0.rawValue, platform) })),
    ])
  }()

  /// `platforms.ios.palette`, which gets its own warning: it is not a typo, it
  /// is a thing the format refuses.
  static func isPlatformPalette(_ path: String) -> Bool {
    let parts = path.split(separator: ".")
    return parts.count == 3 && parts[0] == "platforms" && parts[2] == "palette"
      && ThemePlatform(rawValue: String(parts[1])) != nil
  }

  /// Dotted paths of keys the format does not have, sorted.
  static func unknownKeys(in data: Data) -> [String] {
    guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
    var found: [String] = []
    walk(json, root, path: "", into: &found)
    return found.sorted()
  }

  private static func walk(_ value: Any, _ node: Node, path: String, into found: inout [String]) {
    guard case .object(let children) = node, let object = value as? [String: Any] else { return }
    for (key, child) in object {
      let childPath = path.isEmpty ? key : "\(path).\(key)"
      guard let schema = children[key] else {
        found.append(childPath)
        continue
      }
      walk(child, schema, path: childPath, into: &found)
    }
  }
}
