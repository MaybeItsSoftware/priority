import PriorityCore

/// A swappable look: a colour palette and a structure set, under an identity.
///
/// The contract sits in its own file rather than in `PluginProtocols.swift`,
/// and `Native/Theme/` is excluded from the `PriorityPlugins` target, for the
/// same reason `DailyLogPlugin` is: a theme traffics in `PriorityCore` types
/// (`ThemePalette`, `ThemeStructure`, `ThemeSpecification`), a file can only
/// belong to one SPM target, and the Xcode app compiles everything as one
/// module. Nothing is lost — the palette arithmetic lives in
/// `Sources/PriorityCore/Theming/` and is covered by `corelogic-tests`.
///
/// Like `CompletionCelebrationPlugin`, this is a menu rather than an
/// integration: every theme registers, and the user's pick is applied
/// afterwards by `ThemeManager`.
@MainActor
protocol ThemePlugin: Plugin {
  /// SF Symbol shown next to the theme's name in the picker.
  var themeIconSystemName: String { get }

  /// Payload one: the colours, as two tables of literal hex read through
  /// semantic roles.
  var palette: ThemePalette { get }

  /// Payload two: radii, border weights, the spacing scale and the type
  /// treatment — everything about the look that is not colour.
  var structure: ThemeStructure { get }

  /// Advisory only. A theme may say which appearance it was drawn for, so the
  /// settings page can mention it; the appearance actually in force stays the
  /// user's own light/dark/system choice.
  var lockedAppearance: ThemeAppearance? { get }

  /// The two payloads plus the identity, as the one value the rest of the app
  /// passes around. Defaulted — a plugin supplies the parts.
  var specification: ThemeSpecification { get }
}

extension ThemePlugin {
  var themeIconSystemName: String { "paintpalette" }
  var lockedAppearance: ThemeAppearance? { nil }

  var specification: ThemeSpecification {
    ThemeSpecification(
      identifier: pluginIdentifier,
      name: displayName,
      summary: pluginDescription,
      lockedAppearance: lockedAppearance,
      palette: palette,
      structure: structure
    )
  }
}
