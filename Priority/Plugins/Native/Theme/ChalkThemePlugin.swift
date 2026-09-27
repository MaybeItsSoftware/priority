import PriorityCore

/// The house style, and the default.
///
/// Four lines of substance: the palette and the structure are
/// `BuiltInThemeSpecifications.chalk`'s, because that is where they can be
/// tested. A plugin here is a registration, not a place to keep hex.
@MainActor
struct ChalkThemePlugin: ThemePlugin {
  private let specificationValue = BuiltInThemeSpecifications.chalk

  var pluginIdentifier: String { specificationValue.identifier }
  var displayName: String { "Chalk Theme" }
  var pluginDescription: String { specificationValue.summary }
  var themeIconSystemName: String { "doc.plaintext" }

  var palette: ThemePalette { specificationValue.palette }
  var structure: ThemeStructure { specificationValue.structure }
  var lockedAppearance: ThemeAppearance? { specificationValue.lockedAppearance }
}
