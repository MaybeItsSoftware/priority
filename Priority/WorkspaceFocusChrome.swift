import SwiftUI

/// The small shared vocabulary every focus surface is built from — the pane,
/// the summoned panel, and the context bar.
///
/// It exists so the three of them cannot drift. Before this, each surface set
/// its own caption size, tracking and key-cap padding inline, and they had
/// already diverged by a point here and a corner radius there.

/// 10pt, bold, uppercase, widely tracked, muted. Section eyebrows, column
/// headers and chip captions all use it, so hierarchy reads from surface and
/// position rather than from label size.
struct MicroLabel: View {
  let text: String
  var tint: Color?

  init(_ text: String, tint: Color? = nil) {
    self.text = text
    self.tint = tint
  }

  var body: some View {
    Text(text.uppercased())
      .font(.system(size: 10, weight: .bold))
      .tracking(1.5)
      .foregroundStyle(tint ?? Color.secondary)
  }
}

/// A key drawn as a key. Every action that has a shortcut shows it here rather
/// than in a reference sheet, because a shortcut you have to go and look up is
/// a shortcut nobody learns.
struct KeyCap: View {
  let key: String

  init(_ key: String) { self.key = key }

  var body: some View {
    Text(key)
      .font(.system(size: 10, weight: .medium, design: .monospaced))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
      .overlay(
        RoundedRectangle(cornerRadius: 4)
          .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
  }
}

/// `key` then `label`, for the hint rows along the foot of a focus surface.
struct KeyHint: View {
  let key: String
  let label: String

  init(_ key: String, _ label: String) {
    self.key = key
    self.label = label
  }

  var body: some View {
    HStack(spacing: 5) {
      KeyCap(key)
      Text(label)
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
  }
}

/// The hairline that separates one band of a focus surface from the next.
/// Separation is a 1px rule here, never a shadow and never a nested card.
struct FocusRule: View {
  var body: some View {
    Rectangle()
      .fill(Color.primary.opacity(0.08))
      .frame(height: 1)
  }
}
