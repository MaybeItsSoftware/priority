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

/// A toggle as Zed's settings draw one: the label on the left, a small
/// switch on the right. Off is a hairline track on the well; on fills the
/// track with the primary status tint and slides the knob across. The whole
/// row is the hit target, and it is a button underneath, so Space and
/// VoiceOver work as they did on the stock control.
///
/// It replaced a themed checkbox, which was flat and on-palette but still a
/// checkbox: a column of squares down the left of the inspector read as a
/// form from System Settings however it was coloured.
struct ThemedSwitchToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    ThemedSwitch(configuration: configuration)
  }
}

private struct ThemedSwitch: View {
  @Environment(\.theme) private var theme
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let configuration: ToggleStyleConfiguration

  var body: some View {
    let isOn = configuration.isOn
    let height = theme.scale.body
    let width = height * 1.75
    let inset = theme.hairline * 2
    Button {
      configuration.isOn.toggle()
    } label: {
      HStack(spacing: theme.space.sm) {
        configuration.label
          .font(theme.bodyFont())
          .foregroundStyle(theme.ink)
          .multilineTextAlignment(.leading)
        Spacer(minLength: theme.space.sm)
        // A track and its knob are genuinely round things, the one place
        // the radius scale allows a capsule.
        Capsule()
          .fill(isOn ? theme.primary.opacity(Theme.statusBorderOpacity) : theme.well)
          .overlay(
            Capsule().strokeBorder(
              isOn ? theme.primary.opacity(Theme.statusBorderOpacity) : theme.inputBorder,
              lineWidth: theme.hairline))
          .overlay(alignment: isOn ? .trailing : .leading) {
            Circle()
              .fill(isOn ? theme.primary : theme.muted)
              .padding(inset * 1.5)
          }
          .frame(width: width, height: height)
          .animation(.easeOut(duration: reduceMotion ? 0.01 : 0.12), value: isOn)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .opacity(isEnabled ? 1 : 0.45)
    .accessibilityValue(isOn ? "On" : "Off")
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}

extension ToggleStyle where Self == ThemedSwitchToggleStyle {
  static var themedSwitch: ThemedSwitchToggleStyle { ThemedSwitchToggleStyle() }
}

/// A date as a themed control: the date written out in the control frame,
/// opening a calendar beneath it. The stock `DatePicker` field is a bezelled
/// stepper of AppKit's own, with its own accent, and no theme reaches it.
///
/// The calendar in the popover is still the system's graphical picker —
/// redrawing a month grid would be a lot of code for no gain in a popover,
/// which already sits on its own surface — but nothing system-drawn is left
/// in the panel itself.
struct ThemedDateField: View {
  @Environment(\.theme) private var theme
  @Binding var selection: Date
  var includesTime = false
  @State private var isPicking = false

  private var title: String {
    let day = selection.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    let calendar = Calendar.current
    let year = calendar.component(.year, from: selection) == calendar.component(.year, from: .now)
      ? "" : " \(calendar.component(.year, from: selection))"
    guard includesTime else { return day + year }
    return day + year + ", " + selection.formatted(date: .omitted, time: .shortened)
  }

  var body: some View {
    Button { isPicking.toggle() } label: {
      Label(title, systemImage: "calendar")
        .labelStyle(.titleAndIcon)
        .monospacedDigit()
        .lineLimit(1)
    }
    .buttonStyle(.plain)
    .fixedSize()
    .themedControlFrame()
    .focusable()
    .popover(isPresented: $isPicking, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: theme.space.sm) {
        DatePicker("", selection: $selection, displayedComponents: [.date])
          .datePickerStyle(.graphical)
          .labelsHidden()
        if includesTime {
          ThemedControlRow("Time") {
            DatePicker("", selection: $selection, displayedComponents: [.hourAndMinute])
              .datePickerStyle(.field)
              .labelsHidden()
          }
        }
        HStack(spacing: theme.space.xs) {
          Button("Today") { selection = Self.moving(selection, toDayOf: .now) }
          Button("Tomorrow") {
            selection = Self.moving(
              selection, toDayOf: Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now)
          }
          Spacer()
          Button("Done") { isPicking = false }
            .keyboardShortcut(.defaultAction)
        }
        .buttonStyle(FocusChipButtonStyle(isOn: false))
      }
      .font(theme.bodyFont())
      .padding(theme.space.md)
      .background(theme.raised)
    }
  }

  /// The same time of day on another day, so "Today" on a deadline at 17:00
  /// keeps the 17:00.
  private static func moving(_ date: Date, toDayOf day: Date) -> Date {
    let calendar = Calendar.current
    let time = calendar.dateComponents([.hour, .minute], from: date)
    return calendar.date(
      bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0,
      of: day) ?? day
  }
}

/// A value a task may or may not have — a start, a due day — as one row: its
/// name, then either a quiet "Add" or the value with a button to clear it.
/// What a checkbox beside a field used to say in two controls and two lines.
struct ThemedOptionalRow<Value: View>: View {
  @Environment(\.theme) private var theme
  let title: String
  let isSet: Bool
  let add: () -> Void
  let clear: () -> Void
  @ViewBuilder var value: Value

  init(
    _ title: String, isSet: Bool, add: @escaping () -> Void, clear: @escaping () -> Void,
    @ViewBuilder value: () -> Value
  ) {
    self.title = title
    self.isSet = isSet
    self.add = add
    self.clear = clear
    self.value = value()
  }

  var body: some View {
    ThemedControlRow(title) {
      if isSet {
        HStack(spacing: theme.space.xs) {
          value
          Button(action: clear) {
            Image(systemName: "xmark")
              .font(theme.captionFont)
              .foregroundStyle(theme.muted)
              .frame(width: theme.scale.body, height: theme.scale.body)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .focusable()
          .help("Clear \(title.lowercased())")
          .accessibilityLabel("Clear \(title.lowercased())")
        }
      } else {
        Button(action: add) {
          Label("Add", systemImage: "plus")
            .labelStyle(.titleAndIcon)
        }
        .buttonStyle(FocusChipButtonStyle(isOn: false))
        .focusable()
        .accessibilityLabel("Add \(title.lowercased())")
      }
    }
  }
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
