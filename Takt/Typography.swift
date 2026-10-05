import AppKit
import SwiftUI

enum Typography {
  static var interfaceFont: Font {
    .system(.body, design: .default)
  }

  static func interfaceNSFont(ofSize size: CGFloat) -> NSFont {
    .systemFont(ofSize: size)
  }

  static func taskFont(size: CGFloat, name: String = "System Font", weight: Font.Weight = .regular) -> Font {
    if name != "System Font", !name.isEmpty {
      return Font.custom(name, size: size).weight(weight)
    }
    return .system(size: size, weight: weight, design: .default)
  }

  static func taskNSFont(ofSize size: CGFloat, name: String = "System Font") -> NSFont {
    if name != "System Font", !name.isEmpty, let font = NSFont(name: name, size: size) {
      return font
    }
    return .systemFont(ofSize: size)
  }
}
