import SwiftUI

/// The face of a "Sign in with Google" or "Sign in with Apple" button, shared
/// by the Mac and iOS settings screens.
///
/// Each brand's own rules for colour, mark and wording, set flat at the apps'
/// 6px control radius with a hairline instead of a shadow. The colours are
/// the brands', fixed rather than themed, the way a photo's letterbox is: the
/// marks aren't ours to recolour. Only the mode follows the system, as both
/// brands ask: Google's light or dark button, Apple's black or white one.
public struct SyncProviderButtonLabel: View {
  public enum Brand: Sendable {
    case google
    case apple
  }

  let brand: Brand
  let font: Font
  let height: CGFloat
  @Environment(\.colorScheme) private var colorScheme

  public init(_ brand: Brand, font: Font = .system(size: 14, weight: .medium), height: CGFloat = 36) {
    self.brand = brand
    self.font = font
    self.height = height
  }

  public var body: some View {
    HStack(spacing: 10) {
      mark
      Text(brand == .google ? "Sign in with Google" : "Sign in with Apple")
        .font(font)
        .lineLimit(1)
    }
    .foregroundStyle(text)
    .padding(.horizontal, 12)
    .frame(maxWidth: .infinity, minHeight: height)
    .background(fill, in: RoundedRectangle(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(border, lineWidth: 1))
    .contentShape(RoundedRectangle(cornerRadius: 6))
  }

  @ViewBuilder
  private var mark: some View {
    switch brand {
    case .google: GoogleMark().frame(width: 18, height: 18)
    case .apple: Image(systemName: "apple.logo").font(.system(size: 16, weight: .medium))
    }
  }

  private var isDark: Bool { colorScheme == .dark }

  // Google: #FFFFFF / #1F1F1F / #747775 light; #131314 / #E3E3E3 / #8E918F dark.
  // Apple: black with white in light mode, white with black in dark.
  private var fill: Color {
    switch brand {
    case .google: isDark ? Color(hex: 0x131314) : .white
    case .apple: isDark ? .white : .black
    }
  }

  private var text: Color {
    switch brand {
    case .google: Color(hex: isDark ? 0xE3E3E3 : 0x1F1F1F)
    case .apple: isDark ? .black : .white
    }
  }

  private var border: Color {
    switch brand {
    case .google: Color(hex: isDark ? 0x8E918F : 0x747775)
    case .apple: isDark ? .white : .black
    }
  }
}

/// Google's four-colour "G", drawn rather than shipped as an image.
struct GoogleMark: View {
  var body: some View {
    Canvas { context, size in
      let side = min(size.width, size.height)
      let width = side * 0.2
      let radius = (side - width) / 2
      let center = CGPoint(x: size.width / 2, y: size.height / 2)
      // Clockwise from three o'clock, with the opening at the upper right.
      let arcs: [(Double, Double, Color)] = [
        (0, 45, Color(hex: 0x4285F4)),
        (45, 150, Color(hex: 0x34A853)),
        (150, 210, Color(hex: 0xFBBC05)),
        (210, 318, Color(hex: 0xEA4335)),
      ]
      for (start, end, color) in arcs {
        var arc = Path()
        arc.addArc(
          center: center, radius: radius, startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
        context.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .butt))
      }
      let bar = CGRect(x: center.x, y: center.y - width / 2, width: radius + width / 2, height: width)
      context.fill(Path(bar), with: .color(Color(hex: 0x4285F4)))
    }
    .accessibilityHidden(true)
  }
}

extension Color {
  fileprivate init(hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
  }
}
