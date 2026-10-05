import TaktCore

/// The Zed look with the lights off.
///
/// It shares Chalk's palette object outright and differs only in fixing the
/// appearance, so the two can never drift apart — a dark mode that had to be
/// kept in step with a light one by hand is a dark mode that eventually is
/// not.
@MainActor
struct ChalkDarkThemePlugin: ThemePlugin {
  private let specificationValue = BuiltInThemeSpecifications.chalkDark

  var pluginIdentifier: String { specificationValue.identifier }
  var displayName: String { "Chalk Dark Theme" }
  var pluginDescription: String { specificationValue.summary }
  var themeIconSystemName: String { "moon.fill" }

  var palette: ThemePalette { specificationValue.palette }
  var structure: ThemeStructure { specificationValue.structure }
  var lockedAppearance: ThemeAppearance? { specificationValue.lockedAppearance }
}
