import PriorityCore
import SwiftUI

// The inspector's controls, drawn by the theme.
//
// The stock ones — the grey pop-up `Picker`, the `.switch` toggle, the
// rounded-bezel text field — each paint a bezel and an accent of the system's
// own that no theme can reach, so a dock of them read as System Settings
// dropped into the app. These are the same controls with the same bindings,
// drawn flat: a hairline rectangle at the control radius, the theme's faces,
// and primary only where something is on.

/// A label on the left and its control on the right, one line high. Dense
/// on purpose: the inspector is a panel you scan, not a form you fill in.
struct ThemedControlRow<Control: View>: View {
  @Environment(\.theme) private var theme
  let title: String
  @ViewBuilder var control: Control

  init(_ title: String, @ViewBuilder control: () -> Control) {
    self.title = title
    self.control = control()
  }

  var body: some View {
    HStack(spacing: theme.space.sm) {
      Text(title)
        .font(theme.bodyFont())
        .foregroundStyle(theme.ink)
        .lineLimit(1)
      Spacer(minLength: theme.space.sm)
      control
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The frame every themed control sits in: a hairline at the control radius,
/// on the raised surface, with the theme's padding.
private struct ThemedControlFrame: ViewModifier {
  @Environment(\.theme) private var theme
  var expands: Bool

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
    content
      .font(theme.bodyFont())
      .foregroundStyle(theme.ink)
      .padding(.horizontal, theme.space.sm)
      .padding(.vertical, theme.space.xs)
      .frame(maxWidth: expands ? .infinity : nil, alignment: .leading)
      .background(shape.fill(theme.raised))
      .overlay(shape.strokeBorder(theme.inputBorder, lineWidth: theme.hairline))
      .contentShape(shape)
  }
}

extension View {
  /// Puts a control in the themed frame. `expands` takes the row's width, for
  /// a field; otherwise the frame hugs its content, for a menu.
  func themedControlFrame(expands: Bool = false) -> some View {
    modifier(ThemedControlFrame(expands: expands))
  }

  /// A text field drawn by the theme instead of the rounded bezel.
  func themedTextField() -> some View {
    textFieldStyle(.plain).themedControlFrame(expands: true)
  }
}

/// One choice in a `ThemedPicker`.
struct ThemedPickerOption<Value: Hashable>: Identifiable {
  let title: String
  let value: Value
  var systemImage: String?

  var id: Value { value }

  init(_ title: String, value: Value, systemImage: String? = nil) {
    self.title = title
    self.value = value
    self.systemImage = systemImage
  }
}

/// A `Picker` in a themed frame. The menu it opens is still the system's,
/// with the system's checkmark — only the closed control is redrawn — so
/// choosing works exactly as the pop-up it replaced.
struct ThemedPicker<Value: Hashable>: View {
  @Environment(\.theme) private var theme
  let title: String
  @Binding var selection: Value
  let options: [ThemedPickerOption<Value>]

  init(_ title: String, selection: Binding<Value>, options: [ThemedPickerOption<Value>]) {
    self.title = title
    _selection = selection
    self.options = options
  }

  var body: some View {
    ThemedControlRow(title) { ThemedMenuPicker(title, selection: $selection, options: options) }
  }
}

/// The closed control of a `ThemedPicker`, without the row's label, for a
/// place that names the choice some other way.
struct ThemedMenuPicker<Value: Hashable>: View {
  @Environment(\.theme) private var theme
  let title: String
  @Binding var selection: Value
  let options: [ThemedPickerOption<Value>]

  init(_ title: String, selection: Binding<Value>, options: [ThemedPickerOption<Value>]) {
    self.title = title
    _selection = selection
    self.options = options
  }

  private var current: ThemedPickerOption<Value>? { options.first { $0.value == selection } }

  var body: some View {
    ThemedMenu(current?.title ?? title, systemImage: current?.systemImage) {
      Picker(title, selection: $selection) {
        ForEach(options) { option in
          if let symbol = option.systemImage {
            Label(option.title, systemImage: symbol).tag(option.value)
          } else {
            Text(option.title).tag(option.value)
          }
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()
    }
    .accessibilityLabel(title)
  }
}

/// A menu whose closed state is a themed rectangle rather than a grey
/// pop-up: its title, a small chevron, a hairline.
struct ThemedMenu<Content: View>: View {
  @Environment(\.theme) private var theme
  let title: String
  var systemImage: String?
  var expands = false
  @ViewBuilder var content: Content

  init(
    _ title: String, systemImage: String? = nil, expands: Bool = false,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.systemImage = systemImage
    self.expands = expands
    self.content = content()
  }

  var body: some View {
    Menu {
      content
    } label: {
      // Text and one glyph, nothing more: a borderless menu on macOS draws
      // its label through AppKit, which flattens anything richer.
      if let systemImage {
        Label(title, systemImage: systemImage)
      } else {
        Text(title)
      }
    }
    // Borderless, so what is drawn is the label and AppKit's small chevron
    // and none of its bezel; the frame round it is the theme's.
    .menuStyle(.borderlessButton)
    .menuIndicator(.visible)
    .lineLimit(1)
    .fixedSize(horizontal: !expands, vertical: true)
    .themedControlFrame(expands: expands)
  }
}

/// A toggle as a themed checkbox: a hairline square at the control radius
/// that fills with the primary status tint and a check when on. The whole row
/// is the hit target, and it is a button underneath, so Space and VoiceOver
/// work as they did on the switch.
struct ThemedCheckboxToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    ThemedCheckbox(configuration: configuration)
  }
}

private struct ThemedCheckbox: View {
  @Environment(\.theme) private var theme
  @Environment(\.isEnabled) private var isEnabled
  let configuration: ToggleStyleConfiguration

  var body: some View {
    let side = theme.scale.body + theme.space.xs
    let shape = RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
    let isOn = configuration.isOn
    Button {
      configuration.isOn.toggle()
    } label: {
      HStack(spacing: theme.space.sm) {
        shape
          .fill(isOn ? theme.primary.opacity(Theme.statusFillOpacity) : theme.raised)
          .overlay(
            shape.strokeBorder(
              isOn ? theme.primary.opacity(Theme.statusBorderOpacity) : theme.inputBorder,
              lineWidth: theme.hairline)
          )
          .overlay {
            if isOn {
              Image(systemName: "checkmark")
                .font(theme.bodyFont(size: side * 0.6, weight: .semibold))
                .foregroundStyle(theme.primary)
            }
          }
          .frame(width: side, height: side)
        configuration.label
          .font(theme.bodyFont())
          .foregroundStyle(theme.ink)
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .opacity(isEnabled ? 1 : 0.45)
    .accessibilityValue(isOn ? "On" : "Off")
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}

extension ToggleStyle where Self == ThemedCheckboxToggleStyle {
  static var themedCheckbox: ThemedCheckboxToggleStyle { ThemedCheckboxToggleStyle() }
}

/// A short set of exclusive choices as a row of themed chips, for where a
/// menu would hide two or three options behind a click.
struct ThemedSegmentedPicker<Value: Hashable>: View {
  @Environment(\.theme) private var theme
  @Binding var selection: Value
  let options: [ThemedPickerOption<Value>]

  var body: some View {
    HStack(spacing: theme.space.xs) {
      ForEach(options) { option in
        Button(option.title) { selection = option.value }
          .buttonStyle(FocusChipButtonStyle(isOn: option.value == selection))
          .accessibilityAddTraits(option.value == selection ? .isSelected : [])
      }
    }
  }
}
