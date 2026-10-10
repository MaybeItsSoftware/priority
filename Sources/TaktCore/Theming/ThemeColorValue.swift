import Foundation
import TaktRustCore

/// A colour, as the theming layer stores one: four channels in 0…1, with no
/// AppKit or SwiftUI anywhere near it.
///
/// `TaktCore` cannot import either, which is the whole reason this type
/// exists rather than the app's `Color`. Resolving and auditing a theme is the
/// Rust core's (`core/src/theme`); the hex parse stays here as well because
/// list colours are parsed per row in view bodies, where a call across the
/// boundary would cost more than the parse.
public struct ThemeColorValue: Equatable, Hashable, Sendable, Codable {
  public let red: Double
  public let green: Double
  public let blue: Double
  public let alpha: Double

  public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
    self.red = Self.clamped(red)
    self.green = Self.clamped(green)
    self.blue = Self.clamped(blue)
    self.alpha = Self.clamped(alpha)
  }

  /// `#rgb`, `#rrggbb` or `#rrggbbaa`, with or without the hash. Anything else
  /// is `nil` — a palette that cannot be read should fail validation rather
  /// than quietly become black.
  public init?(hex raw: String) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let stripped = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
    let digits = stripped.lowercased()
    guard !digits.isEmpty, digits.allSatisfy({ $0.isHexDigit }) else { return nil }

    let expanded: String
    switch digits.count {
    case 3:
      expanded = digits.reduce(into: "") { $0.append(contentsOf: String(repeating: $1, count: 2)) }
    case 6, 8:
      expanded = digits
    default:
      return nil
    }

    func channel(_ offset: Int) -> Double {
      let start = expanded.index(expanded.startIndex, offsetBy: offset)
      let end = expanded.index(start, offsetBy: 2)
      return Double(Int(expanded[start..<end], radix: 16) ?? 0) / 255.0
    }

    self.init(
      red: channel(0),
      green: channel(2),
      blue: channel(4),
      alpha: expanded.count == 8 ? channel(6) : 1
    )
  }

  /// The debug magenta a resolution falls back to when a role is missing from
  /// both tables. Deliberately hideous: `ThemeSpecification.validate()` is
  /// meant to catch that first, so seeing this on screen is a bug report.
  public static let unresolved = ThemeColorValue(red: 1, green: 0, blue: 1)

  public var hexString: String {
    let channels = [red, green, blue].map { Int(($0 * 255).rounded()) }
    let base = String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
    guard alpha < 1 else { return base }
    return base + String(format: "%02X", Int((alpha * 255).rounded()))
  }

  public func withAlpha(_ newAlpha: Double) -> ThemeColorValue {
    ThemeColorValue(red: red, green: green, blue: blue, alpha: newAlpha)
  }

  /// WCAG 2.1 relative luminance, of the opaque colour. Alpha is ignored:
  /// there is no backdrop to composite against here, and a tinted fill's
  /// legibility is checked against the role it sits on rather than the tint.
  public var relativeLuminance: Double { themeRelativeLuminance(color: core) }

  /// WCAG 2.1 contrast ratio, 1…21, symmetric in its arguments. The core's,
  /// the same arithmetic the theme audit uses.
  public func contrastRatio(against other: ThemeColorValue) -> Double {
    themeContrastRatio(a: core, b: other.core)
  }

  private static func clamped(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(max(value, 0), 1)
  }
}
