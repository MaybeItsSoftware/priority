import Foundation
import PriorityCore

/// A theme the user wrote: one JSON file in the themes folder, already merged
/// over whatever it extends by `ThemeFileLoader`.
///
/// Not registered with `PluginRegistry`, because it is not a fixed part of the
/// app — files come and go while it runs. `UserThemeLibrary` vends these and
/// `ThemeManager` lists them after the built-ins.
@MainActor
struct UserThemePlugin: ThemePlugin {
  let specificationValue: ThemeSpecification
  /// Where it came from, so the settings page can say and reveal it.
  let fileURL: URL

  nonisolated var pluginIdentifier: String { specificationValue.identifier }
  nonisolated var displayName: String { specificationValue.name }
  nonisolated var pluginDescription: String { specificationValue.summary }
  var themeIconSystemName: String { "doc.badge.gearshape" }

  var palette: ThemePalette { specificationValue.palette }
  var structure: ThemeStructure { specificationValue.structure }
  var lockedAppearance: ThemeAppearance? { specificationValue.lockedAppearance }
  var specification: ThemeSpecification { specificationValue }
}
