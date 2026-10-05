import TaktCore

/// The default theme: plain greys, one blue and the system's own faces, grown
/// from three seed colours so a themer can start from it by changing three.
///
/// Like the other built-ins, a registration rather than a place to keep hex:
/// the palette and structure are `BuiltInThemeSpecifications.priority`'s.
@MainActor
struct PriorityThemePlugin: ThemePlugin {
  private let specificationValue = BuiltInThemeSpecifications.priority

  var pluginIdentifier: String { specificationValue.identifier }
  var displayName: String { specificationValue.name }
  var pluginDescription: String { specificationValue.summary }
  var themeIconSystemName: String { "circle.lefthalf.filled" }

  var palette: ThemePalette { specificationValue.palette }
  var structure: ThemeStructure { specificationValue.structure }
  var lockedAppearance: ThemeAppearance? { specificationValue.lockedAppearance }
}
