import TaktCore

/// Grape: the house design language — warm paper, grape ink, Arvo and Geist
/// Mono, hairlines and tracked small capitals.
///
/// A registration over `BuiltInThemeSpecifications.grape`, where the palette
/// and structure can be tested.
@MainActor
struct GrapeThemePlugin: ThemePlugin {
  private let specificationValue = BuiltInThemeSpecifications.grape

  var pluginIdentifier: String { specificationValue.identifier }
  var displayName: String { "Grape Theme" }
  var pluginDescription: String { specificationValue.summary }
  var themeIconSystemName: String { "textformat" }

  var palette: ThemePalette { specificationValue.palette }
  var structure: ThemeStructure { specificationValue.structure }
  var lockedAppearance: ThemeAppearance? { specificationValue.lockedAppearance }
}
