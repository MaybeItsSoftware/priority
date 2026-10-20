import SwiftUI
import TaktCore

/// A task's completion mark: a hairline square at the control radius scaled
/// down to the box — never a circle, which the user asked to be rid of
/// everywhere a task is ticked. Empty when open; done is the box tinted with
/// the success hue, its border and a check; cancelled is the same in the
/// danger hue with a cross.
struct TaskCheckBox: View {
  enum Status {
    case open, done, cancelled
  }

  @Environment(\.theme) private var theme
  var state: Status = .open
  /// The box's side; the body size when nil, so it sits where a glyph would.
  var size: CGFloat?

  init(state: Status = .open, size: CGFloat? = nil) {
    self.state = state
    self.size = size
  }

  init(isDone: Bool, size: CGFloat? = nil) {
    self.init(state: isDone ? .done : .open, size: size)
  }

  var body: some View {
    let side = size ?? CGFloat(theme.scale.body * 0.9).rounded()
    let shape = RoundedRectangle(cornerRadius: min(theme.controlRadius, side / 4), style: .continuous)
    ZStack {
      shape.fill(hue.map { $0.opacity(Theme.statusFillOpacity) } ?? Color.clear)
      shape.strokeBorder(
        hue.map { $0.opacity(Theme.statusBorderOpacity) } ?? theme.inputBorder,
        lineWidth: max(1, theme.hairline))
      if let mark {
        Image(systemName: mark)
          .font(.system(size: side * 0.6, weight: .bold))
          .foregroundStyle(hue ?? theme.muted)
      }
    }
    .frame(width: side, height: side)
    .accessibilityHidden(true)
  }

  private var hue: Color? {
    switch state {
    case .open: nil
    case .done: theme.success
    case .cancelled: theme.danger
    }
  }

  private var mark: String? {
    switch state {
    case .open: nil
    case .done: "checkmark"
    case .cancelled: "xmark"
    }
  }
}
