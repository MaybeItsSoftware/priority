import SwiftUI
import UIKit

/// The few Chalk colours the widgets draw with. The app resolves its palette
/// from PriorityCore's theme specification; the widget extension does not link
/// the package, so these are the same hexes, ported.
enum ChalkColors {
  static let paper = dynamic(light: 0xfaf8f4, dark: 0x1c1a23)
  static let raised = dynamic(light: 0xffffff, dark: 0x25232f)
  static let well = dynamic(light: 0xedebef, dark: 0x2d2b38)
  static let border = dynamic(light: 0xe6e4ea, dark: 0x34313f)
  static let ink = dynamic(light: 0x444054, dark: 0xf5f4f7)
  static let muted = dynamic(light: 0x6e6b7c, dark: 0xb6b3bf)
  static let dim = dynamic(light: 0xb6b3bf, dark: 0x6e6b7c)
  static let azure = rgb(0x007fff)
  static let emerald = rgb(0x4cc38e)
  static let raspberry = rgb(0xd62246)
  static let amber = rgb(0xffbf00)

  static func rgb(_ hex: UInt32) -> Color {
    Color(uiColor: uiColor(hex))
  }

  static func uiColor(_ hex: UInt32) -> UIColor {
    UIColor(
      red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
      blue: CGFloat(hex & 0xff) / 255, alpha: 1)
  }

  private static func dynamic(light: UInt32, dark: UInt32) -> Color {
    Color(uiColor: UIColor { traits in
      uiColor(traits.userInterfaceStyle == .dark ? dark : light)
    })
  }
}

/// Plex Sans and Lilex, as the widgets name them.
enum WidgetType {
  static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .custom("IBM Plex Sans", size: size).weight(weight)
  }

  static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .custom("Lilex", size: size).weight(weight).monospacedDigit()
  }

  /// `25m`, `1h 30m`.
  static func duration(_ seconds: Int) -> String {
    let minutes = max(0, seconds) / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    let rest = minutes % 60
    return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
  }
}
