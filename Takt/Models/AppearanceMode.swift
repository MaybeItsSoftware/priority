import Foundation

/// Light, dark, or whatever the desktop is set to.
///
/// Separate from the theme on purpose: a theme says what the colours are, and
/// this says which half of them is in force. A theme with a locked appearance
/// (Zed Dark) overrides it, because choosing that theme by name is choosing
/// that appearance. Stored as its raw value under the old `appThemeRawValue`
/// key, so the numbers are storage and must not be renumbered.
enum AppearanceMode: Int, CaseIterable, Identifiable {
  case system
  case light
  case dark

  var id: Int { rawValue }

  var title: String {
    switch self {
    case .system: return "System"
    case .light: return "Light"
    case .dark: return "Dark"
    }
  }
}
