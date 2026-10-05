import AppKit
import SwiftUI

enum AppThemeColorCodec {
  static func normalizedHex(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let stripped = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
    let uppercased = stripped.uppercased()

    let expanded: String
    if uppercased.count == 3 {
      expanded = uppercased.reduce(into: "") { partial, character in
        partial.append(character)
        partial.append(character)
      }
    } else if uppercased.count == 6 {
      expanded = uppercased
    } else {
      return nil
    }

    guard expanded.range(of: "^[0-9A-F]{6}$", options: .regularExpression) != nil else {
      return nil
    }
    return "#\(expanded)"
  }

  static func color(from hex: String) -> Color? {
    guard let nsColor = nsColor(from: hex) else { return nil }
    return Color(nsColor: nsColor)
  }

  static func nsColor(from hex: String) -> NSColor? {
    guard let normalized = normalizedHex(hex) else { return nil }
    let value = String(normalized.dropFirst())
    guard let rgb = Int(value, radix: 16) else { return nil }

    let red = CGFloat((rgb >> 16) & 0xFF) / 255.0
    let green = CGFloat((rgb >> 8) & 0xFF) / 255.0
    let blue = CGFloat(rgb & 0xFF) / 255.0
    return NSColor(red: red, green: green, blue: blue, alpha: 1.0)
  }

  static func hex(from color: Color) -> String? {
    let nsColor = NSColor(color).usingColorSpace(.deviceRGB)
    guard let nsColor else { return nil }
    let red = Int(round(nsColor.redComponent * 255))
    let green = Int(round(nsColor.greenComponent * 255))
    let blue = Int(round(nsColor.blueComponent * 255))
    return String(format: "#%02X%02X%02X", red, green, blue)
  }
}

enum AppThemeColorToken: String, CaseIterable, Identifiable {
  case panelBackground
  case panelDivider
  case panelSurface
  case panelSurfaceElevated
  case selectionBackground
  case selectionForeground
  case focusRing
  case textPrimary
  case textSecondary
  case textMuted
  case link
  case success
  case warning
  case danger

  var id: String { rawValue }

  /// What the token resolves to when no theme is reachable — a view model or a
  /// detached surface that has not been handed the preferences. Only the roles
  /// views actually reach for outside the settings pane are listed with intent;
  /// the rest fall back to the neutral they are named after.
  var fallback: Color {
    switch self {
    case .success: return .green
    case .warning: return .orange
    case .danger: return .red
    case .link: return .accentColor
    case .selectionBackground: return .accentColor.opacity(0.2)
    case .selectionForeground, .focusRing: return .accentColor
    case .panelBackground: return Color(NSColor.windowBackgroundColor)
    case .panelDivider: return Color(NSColor.separatorColor).opacity(0.85)
    case .panelSurface: return .secondary.opacity(0.08)
    case .panelSurfaceElevated: return .secondary.opacity(0.14)
    case .textPrimary: return .primary
    case .textSecondary: return .secondary
    case .textMuted: return .secondary.opacity(0.8)
    }
  }

  var title: String {
    switch self {
    case .panelBackground: return "Panel Background"
    case .panelDivider: return "Panel Divider"
    case .panelSurface: return "Surface"
    case .panelSurfaceElevated: return "Elevated Surface"
    case .selectionBackground: return "Selection Background"
    case .selectionForeground: return "Selection Foreground"
    case .focusRing: return "Focus Ring"
    case .textPrimary: return "Text Primary"
    case .textSecondary: return "Text Secondary"
    case .textMuted: return "Text Muted"
    case .link: return "Link"
    case .success: return "Success"
    case .warning: return "Warning"
    case .danger: return "Danger"
    }
  }
}

struct AppThemeDocument: Codable {
  var version: Int
  var appearance: String
  var accentPreset: String
  var customAccentHex: String
  var colorOverrides: [String: String]
}
