import PriorityCore

/// The alternative, and the proof.
///
/// Pitch shares no hex, no radius and no border weight with Chalk, so a
/// surface that has been migrated onto the tokens looks obviously different
/// under it — and a surface that has not looks exactly the same. That is the
/// whole job: the swap is its own test.
@MainActor
struct PitchThemePlugin: ThemePlugin {
  private let specificationValue = BuiltInThemeSpecifications.pitch

  var pluginIdentifier: String { specificationValue.identifier }
  var displayName: String { "Pitch Theme" }
  var pluginDescription: String { specificationValue.summary }
  var themeIconSystemName: String { "circle.lefthalf.filled" }

  var palette: ThemePalette { specificationValue.palette }
  var structure: ThemeStructure { specificationValue.structure }
  var preferredAppearance: ThemeAppearance? { specificationValue.preferredAppearance }
}
