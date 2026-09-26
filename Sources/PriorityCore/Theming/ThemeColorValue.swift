import Foundation

/// A colour, as the theming layer stores one: four channels in 0…1, with no
/// AppKit or SwiftUI anywhere near it.
///
/// `PriorityCore` cannot import either, which is the whole reason this type
/// exists rather than the app's `Color`. It also means the interesting part —
/// parsing a palette, flipping it between appearances, and checking that the
/// result is legible — is testable without a window.
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
  public var relativeLuminance: Double {
    func linear(_ channel: Double) -> Double {
      channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }

  /// WCAG 2.1 contrast ratio, 1…21, symmetric in its arguments.
  public func contrastRatio(against other: ThemeColorValue) -> Double {
    let first = relativeLuminance
    let second = other.relativeLuminance
    let lighter = max(first, second)
    let darker = min(first, second)
    return (lighter + 0.05) / (darker + 0.05)
  }

  private static func clamped(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(max(value, 0), 1)
  }
}
