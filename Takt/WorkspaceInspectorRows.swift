import TaktCore
import SwiftUI

// The inspector's own quiet controls.
//
// The inspector used to be a column of boxed groups, each under its own
// eyebrow, each control in its own hairline frame — twenty-odd rectangles
// for a panel you mostly glance at. These draw it the way an editor draws a
// property list: a muted label in one column, the value beside it as plain
// text, and a frame only round the field that has the caret. A value a task
// does not have is one dim "Add …" in the value column, not an empty control.

extension Theme {
  /// The inspector's label column. Wide enough for its longest label —
  /// "Waiting on", "Min. block" — at the body size, so the values beside them
  /// start on one line down the whole panel.
  var inspectorLabelWidth: CGFloat { CGFloat(scale.body) * 7 }
}

/// One line of the inspector: its name, muted, in the label column every
/// row shares, and its value beside it.
struct InspectorRow<Value: View>: View {
  @Environment(\.theme) private var theme
  let label: String
  @ViewBuilder var value: Value

  init(_ label: String, @ViewBuilder value: () -> Value) {
    self.label = label
    self.value = value()
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: theme.space.sm) {
      Text(label)
        .font(theme.bodyFont())
        .foregroundStyle(theme.muted)
        .lineLimit(1)
        .frame(width: theme.inspectorLabelWidth, alignment: .leading)
      VStack(alignment: .leading, spacing: theme.space.xxs) {
        value
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A group of rows that belong together, banded while one of them has the
/// keyboard. Groups are told apart by the hairline between them, not by a
/// heading: the labels already say what each row is.
struct InspectorGroup<Content: View>: View {
  @Environment(\.theme) private var theme
  @ViewBuilder var content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: theme.space.xxs) {
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .inspectorBand()
  }
}

/// How loud a quiet value is: ink for a value, dim for an "Add …" that
/// stands in for one, muted for a secondary action.
enum InspectorTone {
  case ink, muted, dim

  func color(_ theme: Theme) -> Color {
    switch self {
    case .ink: theme.ink
    case .muted: theme.muted
    case .dim: theme.dim
    }
  }
}

/// A value you can click, drawn as its text: no frame, a hover fill, and the
/// same inset a field's text has, so a menu's value, a date and a typed
/// estimate all start on the same line.
struct InspectorValueButtonStyle: ButtonStyle {
  var tone: InspectorTone = .ink

  func makeBody(configuration: Configuration) -> some View {
    InspectorValueButtonBody(configuration: configuration, tone: tone)
  }
}

private struct InspectorValueButtonBody: View {
  @Environment(\.theme) private var theme
  @Environment(\.isEnabled) private var isEnabled
  let configuration: ButtonStyleConfiguration
  let tone: InspectorTone
  @State private var isHovering = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
    configuration.label
      .font(theme.bodyFont())
      .foregroundStyle(isHovering && tone != .ink ? theme.ink : tone.color(theme))
      .lineLimit(1)
      .padding(.horizontal, theme.space.xs)
      .padding(.vertical, theme.space.xxs)
      .background(shape.fill(configuration.isPressed ? theme.well : (isHovering ? theme.hover : .clear)))
      .opacity(isEnabled ? 1 : Theme.disabledOpacity)
      .contentShape(shape)
      .onHover { isHovering = $0 }
  }
}

/// A menu drawn as a quiet value: its title as text, no chevron, no frame.
/// The menu itself is still the system's.
struct InspectorMenu<Content: View>: View {
  let title: String
  var systemImage: String?
  var tone: InspectorTone = .ink
  @ViewBuilder var content: Content

  init(
    _ title: String, systemImage: String? = nil, tone: InspectorTone = .ink,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.systemImage = systemImage
    self.tone = tone
    self.content = content()
  }

  var body: some View {
    Menu {
      content
    } label: {
      if let systemImage {
        Label(title, systemImage: systemImage)
      } else {
        Text(title)
      }
    }
    // A button-style menu draws its label as SwiftUI does, so the quiet
    // style reaches it; a borderless one hands it to AppKit.
    .menuStyle(.button)
    .buttonStyle(InspectorValueButtonStyle(tone: tone))
    .menuIndicator(.hidden)
    .fixedSize()
  }
}

/// A one-line field that is a dim "Add …" until it has a value or the
/// keyboard, then the field itself, framed only while it has the caret.
///
/// The same text field throughout — never a button swapped for a field — so
/// a click, Tab, or Return on the inspector's cursor puts the caret straight
/// in. The cursor standing on it rings it without putting the caret in.
struct InspectorTextField: View {
  @Environment(\.theme) private var theme
  @Environment(\.inspectorFocus) private var focus
  @Environment(\.inspectorCursor) private var cursor
  /// What it says while empty and away: "Add estimate".
  let add: String
  /// What it says while empty with the caret in it: "Minutes".
  var hint = ""
  @Binding var text: String
  let stop: String
  /// A unit said after a value, dimly — "min" after an estimate.
  var unit: String?
  var onSubmit: () -> Void = {}
  @State private var isHovering = false

  var body: some View {
    let isFocused = focus?.wrappedValue == stop
    let isCursor = cursor == stop && !isFocused
    let shape = RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
    HStack(alignment: .firstTextBaseline, spacing: theme.space.xs) {
      field(isFocused: isFocused)
      if let unit, !text.isEmpty {
        Text(unit)
          .font(theme.bodyFont())
          .foregroundStyle(theme.dim)
          .fixedSize()
      }
    }
    .padding(.horizontal, theme.space.xs)
    .padding(.vertical, theme.space.xxs)
    .background(shape.fill(isFocused ? theme.raised : (isHovering ? theme.hover : .clear)))
    .overlay(shape.strokeBorder(isFocused ? theme.focusRing : .clear, lineWidth: theme.hairline))
    .overlay(shape.strokeBorder(isCursor ? theme.focusRing : .clear, lineWidth: theme.focusRingWidth))
    .contentShape(shape)
    .onHover { isHovering = $0 }
  }

  private func field(isFocused: Bool) -> some View {
    TextField(add, text: $text, prompt: Text(""))
      .textFieldStyle(.plain)
      .font(theme.bodyFont())
      .foregroundStyle(theme.ink)
      .inspectorField(stop, ringed: false)
      .onSubmit(onSubmit)
      .overlay(alignment: .leading) {
        if text.isEmpty {
          Text(isFocused ? hint : add)
            .font(theme.bodyFont())
            .foregroundStyle(theme.dim)
            .lineLimit(1)
            .allowsHitTesting(false)
        }
      }
  }
}

/// A multi-line field — the notes, the links — that is one dim "Add …" line
/// until it has text or the caret, then opens to its full height.
///
/// The inspector's cursor rings it without putting the caret in, so walking
/// down the panel passes over it; Return opens it and Esc gives the
/// keyboard back.
struct InspectorTextEditor: View {
  @Environment(\.theme) private var theme
  @Environment(\.inspectorFocus) private var focus
  @Environment(\.inspectorCursor) private var cursor
  let add: String
  @Binding var text: String
  let stop: String
  var minHeight: CGFloat = 80
  var maxHeight: CGFloat?
  @State private var isHovering = false

  /// The text view's own inset before the first character, which the dim
  /// "Add …" has to match to sit where typing will start.
  private static let lineFragmentPadding: CGFloat = 5

  var body: some View {
    let isFocused = focus?.wrappedValue == stop
    let isCursor = cursor == stop && !isFocused
    let isOpen = isFocused || !text.isEmpty
    let shape = RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
    let line = CGFloat(theme.scale.body) * 1.5
    TextEditor(text: $text)
      .font(theme.bodyFont())
      .foregroundStyle(theme.ink)
      .scrollContentBackground(.hidden)
      .frame(minHeight: isOpen ? minHeight : line, maxHeight: isOpen ? maxHeight : line)
      .inspectorField(stop, multiline: true, ringed: false)
      .overlay(alignment: .topLeading) {
        if text.isEmpty && !isFocused {
          Text(add)
            .font(theme.bodyFont())
            .foregroundStyle(theme.dim)
            .padding(.leading, Self.lineFragmentPadding)
            .allowsHitTesting(false)
        }
      }
      .padding(.horizontal, CGFloat(theme.space.xs) - Self.lineFragmentPadding)
      .padding(.vertical, theme.space.xxs)
      .background(shape.fill(isFocused ? theme.raised : (isHovering ? theme.hover : .clear)))
      .overlay(shape.strokeBorder(isFocused ? theme.focusRing : .clear, lineWidth: theme.hairline))
      .overlay(shape.strokeBorder(isCursor ? theme.focusRing : .clear, lineWidth: theme.focusRingWidth))
      .onHover { isHovering = $0 }
  }
}

/// A value a task may or may not have — a due day, a start, a follow-up —
/// as one row: a dim "Add …" until it has one, then the value with a quiet
/// button to clear it.
///
/// "Add …" is a stop the cursor rests on, and Return, Space or a click sets
/// the value; reaching it does not, since walking down the panel should never
/// give a task a date.
struct InspectorOptionalRow<Value: View>: View {
  @Environment(\.theme) private var theme
  let title: String
  let addTitle: String
  let isSet: Bool
  let add: () -> Void
  let clear: () -> Void
  /// Its stops' names: `stop` for Add, `stop.clear` for the clear button.
  /// The value names its own.
  var stop: String
  @ViewBuilder var value: Value

  init(
    _ title: String, add addTitle: String, isSet: Bool, stop: String,
    add: @escaping () -> Void, clear: @escaping () -> Void, @ViewBuilder value: () -> Value
  ) {
    self.title = title
    self.addTitle = addTitle
    self.stop = stop
    self.isSet = isSet
    self.add = add
    self.clear = clear
    self.value = value()
  }

  var body: some View {
    InspectorRow(title) {
      if isSet {
        HStack(spacing: theme.space.xxs) {
          value
          InspectorClearButton(label: "Clear \(title.lowercased())", stop: "\(stop).clear", action: clear)
          Spacer(minLength: 0)
        }
      } else {
        Button(addTitle, action: add)
          .buttonStyle(InspectorValueButtonStyle(tone: .dim))
          .inspectorStop(stop, press: add)
      }
    }
  }
}

/// The small × beside a value that takes it away.
struct InspectorClearButton: View {
  @Environment(\.theme) private var theme
  let label: String
  let stop: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(theme.captionFont)
        .frame(width: theme.scale.body, height: theme.scale.body)
    }
    .buttonStyle(InspectorValueButtonStyle(tone: .dim))
    .inspectorStop(stop, press: action)
    .help(label)
    .accessibilityLabel(label)
  }
}
