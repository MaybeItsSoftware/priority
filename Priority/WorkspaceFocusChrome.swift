import PriorityCore
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
  @Environment(\.theme) private var theme
  let text: String
  var tint: Color?

  init(_ text: String, tint: Color? = nil) {
    self.text = text
    self.tint = tint
  }

  // The size, weight, tracking and case are the theme's, not this view's.
  // They were written out here as 10/bold/1.5/uppercase, which is the house
  // figure — but a figure copied into a view is a figure a theme cannot
  // change, and the point of the micro-label is that it is one decision.
  var body: some View {
    Text(text)
      .microLabel(theme, color: tint)
  }
}

/// A key drawn as a key. Every action that has a shortcut shows it here rather
/// than in a reference sheet, because a shortcut you have to go and look up is
/// a shortcut nobody learns.
struct KeyCap: View {
  @Environment(\.theme) private var theme
  let key: String

  init(_ key: String) { self.key = key }

  // A control-radius chip in the monospaced face, bordered rather than
  // filled — rule 1, and the one radius scale rather than the 4 this used.
  var body: some View {
    Text(key)
      .font(theme.monoFont(size: 10, weight: .medium))
      .foregroundStyle(theme.muted)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(theme.well, in: RoundedRectangle(cornerRadius: theme.controlRadius))
      .overlay(
        RoundedRectangle(cornerRadius: theme.controlRadius)
          .strokeBorder(theme.border, lineWidth: theme.hairline))
  }
}

/// `key` then `label`, for the hint rows along the foot of a focus surface.
struct KeyHint: View {
  @Environment(\.theme) private var theme
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
        .font(theme.bodyFont(size: 11))
        .foregroundStyle(theme.dim)
    }
  }
}

/// The hairline that separates one band of a focus surface from the next.
/// Separation is a 1px rule here, never a shadow and never a nested card.
struct FocusRule: View {
  @Environment(\.theme) private var theme

  var body: some View {
    Rectangle()
      .fill(theme.border)
      .frame(height: theme.hairline)
  }
}
