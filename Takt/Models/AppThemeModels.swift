import Foundation

enum AppTheme: Int, CaseIterable {
  case system
  case light
  case dark
}

enum ThemeAccentPreset: String, CaseIterable, Identifiable {
  case blue
  case green
  case orange
  case red
  case violet
  case slate
  case custom

  var id: String { rawValue }

  var title: String {
    switch self {
    case .blue: return "Blue"
    case .green: return "Green"
    case .orange: return "Orange"
    case .red: return "Red"
    case .violet: return "Violet"
    case .slate: return "Slate"
    case .custom: return "Custom"
    }
  }

  var hex: String {
    switch self {
    case .blue: return "#0A84FF"
    case .green: return "#30D158"
    case .orange: return "#FF9F0A"
    case .red: return "#FF453A"
    case .violet: return "#BF5AF2"
    case .slate: return "#8E8E93"
    case .custom: return Self.blue.hex
    }
  }
}
