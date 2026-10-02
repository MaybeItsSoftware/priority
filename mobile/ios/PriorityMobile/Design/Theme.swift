import PriorityCore
import SwiftUI
import UIKit

/// The Chalk palette, resolved from the same specification the Mac app draws
/// from (`BuiltInThemeSpecifications.chalk` in PriorityCore), so a hex changed
/// there changes here. Each colour is a dynamic `UIColor`: it flips with the
/// trait collection, so nothing has to re-render to follow light and dark.
enum Palette {
  static let spec = BuiltInThemeSpecifications.chalk

  static func color(_ role: ThemeColorRole) -> Color {
    Color(uiColor: uiColor(role))
  }

  static func uiColor(_ role: ThemeColorRole) -> UIColor {
    let light = spec.palette.color(role, in: .light)
    let dark = spec.palette.color(role, in: .dark)
    return UIColor { traits in
      let value = traits.userInterfaceStyle == .dark ? dark : light
      return UIColor(red: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
    }
  }

  static let paper = color(.paper)
  static let raised = color(.raised)
  static let altRow = color(.altRow)
  static let hover = color(.hover)
  static let well = color(.well)
  static let border = color(.border)
  static let borderMuted = color(.borderMuted)
  static let inputBorder = color(.inputBorder)
  static let ink = color(.ink)
  static let muted = color(.mutedText)
  static let dim = color(.dimText)
  static let primary = color(.primary)
  static let success = color(.success)
  static let danger = color(.danger)
  static let warning = color(.warning)
  static let purple = color(.categoricalPurple)
  static let pink = color(.categoricalPink)
  static let orange = color(.categoricalOrange)

  /// The colours a list can be given, in the order the picker offers them.
  static let listColors: [(name: String, hex: String)] = [
    ("Azure", "#007fff"), ("Emerald", "#4cc38e"), ("Raspberry", "#d62246"), ("Amber", "#ffbf00"),
    ("Purple", "#7a4de8"), ("Pink", "#ff88dc"), ("Orange", "#ff6b2b"), ("Grape", "#444054"),
  ]

  static func color(hex: String?) -> Color? {
    guard let hex, let value = ThemeColorValue(hex: hex) else { return nil }
    return Color(red: value.red, green: value.green, blue: value.blue, opacity: value.alpha)
  }
}

/// Spacing, radii and hairlines. Zed's proportions: square panels, small
/// control radius, one-pixel rules.
enum Metrics {
  static let xxs: CGFloat = 2
  static let xs: CGFloat = 4
  static let sm: CGFloat = 8
  static let md: CGFloat = 12
  static let lg: CGFloat = 16
  static let xl: CGFloat = 24
  static let controlRadius: CGFloat = 6
  static let cardRadius: CGFloat = 8
  static let hairline: CGFloat = 1 / UIScreen.main.scale
  /// Indent per outline level. Narrower than the Mac's, because a phone runs
  /// out of width four levels down.
  static let indent: CGFloat = 18
  static let minimumHitTarget: CGFloat = 44
}

/// IBM Plex Sans for everything read, Lilex for numerals and code — the pair
/// the Mac app ships. Sizes are relative to Dynamic Type text styles, so the
/// interface scales with the user's setting.
enum Typeface {
  static let sansFamily = "IBM Plex Sans"
  static let monoFamily = "Lilex"

  static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
    .custom(sansFamily, size: size, relativeTo: style).weight(weight)
  }

  static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
    .custom(monoFamily, size: size, relativeTo: style).weight(weight)
  }

  static let body = sans(16)
  static let bodyMedium = sans(16, .medium)
  static let callout = sans(15, relativeTo: .callout)
  static let caption = sans(13, relativeTo: .caption)
  static let footnote = sans(12, relativeTo: .footnote)
  static let title = sans(17, .semibold, relativeTo: .headline)
  static let largeTitle = sans(28, .semibold, relativeTo: .largeTitle)
  static let numeral = mono(13, relativeTo: .caption)
  static let numeralBody = mono(15)
  static let hero = mono(56, .medium, relativeTo: .largeTitle)

  static func uiFont(_ size: CGFloat, weight: UIFont.Weight = .regular, mono: Bool = false) -> UIFont {
    let family = mono ? monoFamily : sansFamily
    let descriptor = UIFontDescriptor(fontAttributes: [
      .family: family,
      .traits: [UIFontDescriptor.TraitKey.weight: weight],
    ])
    let font = UIFont(descriptor: descriptor, size: size)
    return UIFontMetrics.default.scaledFont(for: font)
  }

  /// Sets the UIKit chrome — navigation bars, tab bars, segmented controls —
  /// in Plex rather than San Francisco, on the paper rather than translucent
  /// material. Called once, before the first scene draws.
  @MainActor
  static func applyChrome() {
    let navigation = UINavigationBarAppearance()
    navigation.configureWithOpaqueBackground()
    navigation.backgroundColor = Palette.uiColor(.paper)
    navigation.shadowColor = Palette.uiColor(.border)
    navigation.titleTextAttributes = [
      .font: uiFont(17, weight: .semibold), .foregroundColor: Palette.uiColor(.ink),
    ]
    navigation.largeTitleTextAttributes = [
      .font: uiFont(30, weight: .semibold), .foregroundColor: Palette.uiColor(.ink),
    ]
    let button = UIBarButtonItemAppearance()
    button.normal.titleTextAttributes = [.font: uiFont(16)]
    navigation.buttonAppearance = button
    UINavigationBar.appearance().standardAppearance = navigation
    UINavigationBar.appearance().scrollEdgeAppearance = navigation
    UINavigationBar.appearance().compactAppearance = navigation

    let tab = UITabBarAppearance()
    tab.configureWithOpaqueBackground()
    tab.backgroundColor = Palette.uiColor(.paper)
    tab.shadowColor = Palette.uiColor(.border)
    for item in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
      item.normal.titleTextAttributes = [.font: uiFont(11), .foregroundColor: Palette.uiColor(.mutedText)]
      item.normal.iconColor = Palette.uiColor(.mutedText)
      item.selected.titleTextAttributes = [.font: uiFont(11, weight: .medium), .foregroundColor: Palette.uiColor(.primary)]
      item.selected.iconColor = Palette.uiColor(.primary)
    }
    UITabBar.appearance().standardAppearance = tab
    UITabBar.appearance().scrollEdgeAppearance = tab

    UISegmentedControl.appearance().setTitleTextAttributes([.font: uiFont(13)], for: .normal)
    UISegmentedControl.appearance().setTitleTextAttributes([.font: uiFont(13, weight: .medium)], for: .selected)
  }
}

/// The appearance the user chose. Chalk follows the system by default; the
/// other two pin it.
enum AppearanceChoice: String, CaseIterable, Identifiable {
  case system, light, dark

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system: "Chalk (follow system)"
    case .light: "Chalk light"
    case .dark: "Chalk dark"
    }
  }

  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }

  static let storageKey = "appearanceChoice"
}
