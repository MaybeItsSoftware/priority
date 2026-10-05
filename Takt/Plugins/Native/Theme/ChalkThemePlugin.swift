import TaktCore

/// The Zed look: Plex Sans and Lilex, square panels, warm paper and grape
/// ink. Chalk was its name, and still is in code and in its identifier,
/// because that identifier is stored as people's choice and synced.
///
/// Four lines of substance: the palette and the structure are
/// `BuiltInThemeSpecifications.chalk`'s, because that is where they can be
/// tested. A plugin here is a registration, not a place to keep hex.
@MainActor
struct ChalkThemePlugin: ThemePlugin {
  private let specificationValue = BuiltInThemeSpecifications.chalk

  var pluginIdentifier: String { specificationValue.identifier }
  var displayName: String { specificationValue.name }
  var pluginDescription: String { specificationValue.summary }
  var themeIconSystemName: String { "doc.plaintext" }

  var palette: ThemePalette { specificationValue.palette }
  var structure: ThemeStructure { specificationValue.structure }
  var lockedAppearance: ThemeAppearance? { specificationValue.lockedAppearance }
}
