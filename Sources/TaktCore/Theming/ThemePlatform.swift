import Foundation

/// The app a theme is being resolved for.
///
/// A theme's palette is the same on all three: a role is one colour whatever
/// the device. Its structure is not, because 13pt body text is right at a desk
/// and too small in the hand, so a theme file can lay a partial structure over
/// its own per platform (`platforms.<rawValue>.structure`), and resolution
/// always names the platform it is resolving for. See `docs/themes.md`.
public enum ThemePlatform: String, CaseIterable, Sendable, Codable {
  case macos
  case ios
  case android
}
