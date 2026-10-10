import Foundation
import TaktRustCore

/// The few colours a whole palette can be grown from.
///
/// Writing a theme used to mean choosing 21 colours twice. Most of them are
/// not choices: the eleven neutrals are steps between the page and the text,
/// and anyone hand-picking them is doing arithmetic. So a theme can give
/// `seeds` instead — a background, a foreground and an accent per appearance,
/// and optionally the three status colours — and the neutrals are mixed from
/// them by fixed proportions. Any role the theme also states in `palette` wins
/// over the derived one, so seeds are a starting point, not a cage.
///
/// The arithmetic is part of the format: the Android port reproduces it
/// exactly, and `shared/themes/conformance/` holds both to the same answers.
/// Channels are 0–255 integers, and a mix is `round(a + (b − a) × t)`,
/// computed in that order in doubles and rounded half away from zero.
public struct ThemeSeeds: Equatable, Sendable {
  public enum Key: String, CaseIterable, Sendable {
    case background, foreground, accent, success, danger, warning
  }

  public var background: ThemeColorValue?
  public var foreground: ThemeColorValue?
  public var accent: ThemeColorValue?
  public var success: ThemeColorValue?
  public var danger: ThemeColorValue?
  public var warning: ThemeColorValue?

  public init(
    background: ThemeColorValue? = nil, foreground: ThemeColorValue? = nil,
    accent: ThemeColorValue? = nil, success: ThemeColorValue? = nil,
    danger: ThemeColorValue? = nil, warning: ThemeColorValue? = nil
  ) {
    self.background = background
    self.foreground = foreground
    self.accent = accent
    self.success = success
    self.danger = danger
    self.warning = warning
  }

  public subscript(key: Key) -> ThemeColorValue? {
    get {
      switch key {
      case .background: return background
      case .foreground: return foreground
      case .accent: return accent
      case .success: return success
      case .danger: return danger
      case .warning: return warning
      }
    }
    set {
      switch key {
      case .background: background = newValue
      case .foreground: foreground = newValue
      case .accent: accent = newValue
      case .success: success = newValue
      case .danger: danger = newValue
      case .warning: warning = newValue
      }
    }
  }

  /// The seeds a resolved table already implies: its page, its ink, its
  /// primary and its status colours. A file's seeds are laid over these, so
  /// a theme that extends another can change only its accent and keep the
  /// rest.
  public init(implicitIn table: [ThemeColorRole: ThemeColorValue]) {
    self.init(
      background: table[.paper], foreground: table[.ink], accent: table[.primary],
      success: table[.success], danger: table[.danger], warning: table[.warning])
  }

  /// `self`, with every seed `overrides` states laid over it.
  public func overlaid(with overrides: ThemeSeeds) -> ThemeSeeds {
    var merged = self
    for key in Key.allCases where overrides[key] != nil { merged[key] = overrides[key] }
    return merged
  }

  /// The roles these seeds paint in `appearance`, or `nil` without both a
  /// background and a foreground — there is nothing to mix between.
  ///
  /// `raised` is the one neutral that does not head towards the text: a card
  /// sits *above* the page, which in the light is whiter and in the dark is a
  /// step lighter. The arithmetic is the Rust core's (`core/src/theme/seeds.rs`).
  public func roles(in appearance: ThemeAppearance) -> [ThemeColorRole: ThemeColorValue]? {
    let seeds = CoreThemeSeeds(
      background: background?.core, foreground: foreground?.core, accent: accent?.core,
      success: success?.core, danger: danger?.core, warning: warning?.core)
    return themeSeedRoles(seeds: seeds, appearance: appearance.core).map { roles in
      Dictionary(
        uniqueKeysWithValues: roles.compactMap { key, value in
          ThemeColorRole(rawValue: key).map { ($0, ThemeColorValue(value)) }
        })
    }
  }

  /// `a` moved `t` of the way to `b`, per channel, on whole 0–255 steps. The
  /// result is opaque: seeds describe surfaces, and a translucent page has
  /// nothing behind it to be translucent over.
  public static func mix(_ a: ThemeColorValue, _ b: ThemeColorValue, _ t: Double) -> ThemeColorValue {
    ThemeColorValue(themeMix(a: a.core, b: b.core, t: t))
  }
}
