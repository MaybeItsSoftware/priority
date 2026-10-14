import AppKit
import TaktCore
import SwiftUI

// The inspector's controls, drawn by the theme.
//
// The stock ones — the grey pop-up `Picker`, the `.switch` toggle, the
// rounded-bezel text field — each paint a bezel and an accent of the system's
// own that no theme can reach, so a dock of them read as System Settings
// dropped into the app. These are the same controls with the same bindings,
// drawn flat: a hairline rectangle at the control radius, the theme's faces,
// and primary only where something is on.

/// A control Tab can reach, with the theme's ring round it while it has the
/// keyboard.
///
/// `.focusable()` alone left the ring to the system, and the panes these
/// controls sit in turn the system's focus effect off for themselves and
/// everything in them — so Tab moved through the inspector with nothing on
/// screen saying where it had got to. The ring is drawn here instead, as a
/// selection is everywhere else: a border, not a glow.
private struct KeyboardFocusRing: ViewModifier {
  @Environment(\.theme) private var theme
  @FocusState private var hasKeyboard: Bool
  let radius: CGFloat?

  func body(content: Content) -> some View {
    content
      .focusable()
      .focused($hasKeyboard)
      .focusEffectDisabled()
      .overlay {
        RoundedRectangle(cornerRadius: radius ?? theme.controlRadius, style: .continuous)
          .strokeBorder(hasKeyboard ? theme.focusRing : .clear, lineWidth: theme.focusRingWidth)
          .allowsHitTesting(false)
      }
  }
}

extension View {
  /// Reachable with Tab, Space to press, and ringed while it has the keyboard.
  func keyboardFocusable(radius: CGFloat? = nil) -> some View {
    modifier(KeyboardFocusRing(radius: radius))
  }
}

// MARK: - Inspector stops

/// Where the inspector's keyboard is, by stop name, for the controls inside it.
///
/// The inspector moves its own keyboard rather than leaving it to Tab,
/// because Tab only visits text fields unless Keyboard navigation is switched
/// on in System Settings. Every control names itself instead, and the names
/// arrive in the order they are drawn (`InspectorStopsKey`), which is the
/// order its row cursor walks (`InspectorCursor`).
extension EnvironmentValues {
  @Entry var inspectorFocus: FocusState<String?>.Binding?
  /// The row the inspector's cursor is on while the inspector has the
  /// keyboard, edited or not.
  @Entry var inspectorCursor: String?
  /// Whether that row is being typed into.
  @Entry var inspectorEditing = false
  /// The last "press this" or "step this" the cursor sent a stop.
  @Entry var inspectorStopRequest: InspectorStopRequest?
}

/// A key the cursor hands on to one stop: Return pressing it, ← and → stepping
/// a picker. A serial each time, so the same request twice is two requests.
struct InspectorStopRequest: Equatable {
  enum Kind: Equatable { case press, adjust(Int) }
  let id: String
  let kind: Kind
  let serial: Int
}

/// The inspector's stops, top to bottom. A preference collects them in the
/// order the views are laid out, so the walk follows the layout with no
/// second list to keep in step with it.
struct InspectorStopsKey: PreferenceKey {
  static let defaultValue: [InspectorStopInfo] = []
  static func reduce(value: inout [InspectorStopInfo], nextValue: () -> [InspectorStopInfo]) {
    value += nextValue()
  }
}

private struct InspectorStop: ViewModifier {
  @Environment(\.theme) private var theme
  @Environment(\.inspectorFocus) private var focus
  @Environment(\.inspectorCursor) private var cursor
  @Environment(\.inspectorEditing) private var editing
  @Environment(\.inspectorStopRequest) private var request
  let id: String
  let radius: CGFloat?
  let kind: InspectorStopKind
  /// Whether this modifier draws the cursor's ring. A quiet field draws it
  /// on its own frame instead.
  let ringed: Bool
  let adjust: ((Int) -> Void)?
  let press: (() -> Void)?

  func body(content: Content) -> some View {
    if let focus {
      let isCursor = cursor == id && !(kind.isText && editing)
      Group {
        // A text field takes the keyboard of its own accord; anything else
        // has to be told it may.
        if kind.isText { content } else { content.focusable() }
      }
      .focused(focus, equals: id)
      .focusEffectDisabled()
      .overlay {
        if ringed {
          RoundedRectangle(cornerRadius: radius ?? theme.controlRadius, style: .continuous)
            .strokeBorder(
              isCursor || (!kind.isText && focus.wrappedValue == id) ? theme.focusRing : .clear,
              lineWidth: theme.focusRingWidth)
            .allowsHitTesting(false)
        }
      }
      .onKeyPress(keys: [.leftArrow, .rightArrow], phases: .down) { press in
        guard let adjust, press.modifiers.isEmpty else { return .ignored }
        adjust(press.key == .leftArrow ? -1 : 1)
        return .handled
      }
      .onChange(of: request) { _, request in
        guard let request, request.id == id else { return }
        switch request.kind {
        case .adjust(let offset): adjust?(offset)
        case .press:
          if let press { press() } else { Self.pressWithSpace() }
        }
      }
      .id(id)
      .preference(key: InspectorStopsKey.self, value: [InspectorStopInfo(id, kind: kind)])
    } else if kind.isText {
      content
    } else {
      content.keyboardFocusable(radius: radius)
    }
  }

  /// Presses the control that has the keyboard as Space would: the one way to
  /// open a menu without the mouse. Sent to the window rather than the
  /// application, so it does not go round the workspace's key monitor.
  private static func pressWithSpace() {
    DispatchQueue.main.async {
      guard let window = NSApp.keyWindow else { return }
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        guard
          let event = NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: false, keyCode: 49)
        else { continue }
        window.sendEvent(event)
      }
    }
  }
}

extension View {
  /// A control the inspector's cursor stops on, ringed while it is under the
  /// cursor. `adjust`, for a picker, is what ← and → do to its value; `press`
  /// is what Return does, when it is not what Space would.
  /// Outside the inspector it is `keyboardFocusable`.
  func inspectorStop(
    _ id: String, radius: CGFloat? = nil, adjust: ((Int) -> Void)? = nil, press: (() -> Void)? = nil
  ) -> some View {
    modifier(
      InspectorStop(
        id: id, radius: radius, kind: adjust == nil ? .control : .adjustable, ringed: true, adjust: adjust,
        press: press))
  }

  /// A text field or editor the inspector's cursor stops on. Standing on it
  /// rings it; only editing it puts the caret in.
  func inspectorField(_ id: String, multiline: Bool = false, ringed: Bool = true) -> some View {
    modifier(
      InspectorStop(
        id: id, radius: nil, kind: multiline ? .multilineField : .field, ringed: ringed, adjust: nil, press: nil))
  }
}

/// The band behind the inspector section the cursor is in: the same fill a
/// selected task or list row draws, edge to edge across the dock.
///
/// The rings on single controls said which row the keys would act on but not
/// where you were in a column of twenty-odd of them; the band says that, as
/// the task panes and the sidebar do. A section knows the cursor is in it
/// when the cursor's stop is one of its own, which it learns from the same
/// preference the inspector walks.
private struct InspectorBand: ViewModifier {
  @Environment(\.theme) private var theme
  @Environment(\.inspectorCursor) private var cursor
  @State private var stops: [String] = []

  func body(content: Content) -> some View {
    let isActive = cursor.map(stops.contains) ?? false
    content
      .onPreferenceChange(InspectorStopsKey.self) { stops = $0.map(\.id) }
      .padding(.vertical, theme.space.xs)
      .padding(.horizontal, theme.paneGutter)
      .background(WorkspaceSelectionBackground(isSelected: isActive, hasKeyboard: isActive))
      .padding(.horizontal, -theme.paneGutter)
  }
}

extension View {
  /// Bands the group of inspector controls it wraps while the cursor is in
  /// it. Outside the inspector it changes nothing but its padding.
  func inspectorBand() -> some View {
    modifier(InspectorBand())
  }
}

extension Binding where Value: Hashable {
  /// Steps a picker's value through its options, stopping at the ends.
  func step<Option>(by offset: Int, through options: [ThemedPickerOption<Option>]) where Option == Value {
    guard let index = options.firstIndex(where: { $0.value == wrappedValue }) else { return }
    let next = Swift.min(Swift.max(index + offset, 0), options.count - 1)
    wrappedValue = options[next].value
  }
}

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

  // The menu takes the rest of the row rather than hugging its value, so
  // the whole width beside the label opens it.
  var body: some View {
    HStack(spacing: theme.space.sm) {
      Text(title)
        .font(theme.bodyFont())
        .foregroundStyle(theme.ink)
        .lineLimit(1)
      ThemedMenuPicker(title, selection: $selection, options: options, expands: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The closed control of a `ThemedPicker`, without the row's label, for a
/// place that names the choice some other way.
struct ThemedMenuPicker<Value: Hashable>: View {
  @Environment(\.theme) private var theme
  let title: String
  @Binding var selection: Value
  let options: [ThemedPickerOption<Value>]
  var expands = false

  init(
    _ title: String, selection: Binding<Value>, options: [ThemedPickerOption<Value>], expands: Bool = false
  ) {
    self.title = title
    _selection = selection
    self.options = options
    self.expands = expands
  }

  private var current: ThemedPickerOption<Value>? { options.first { $0.value == selection } }

  var body: some View {
    ThemedMenu(current?.title ?? title, systemImage: current?.systemImage, expands: expands) {
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
    // Expanded, the menu itself is stretched rather than only its frame, so
    // a click anywhere in the frame opens it.
    .frame(maxWidth: expands ? .infinity : nil, alignment: .leading)
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
    .opacity(isEnabled ? 1 : Theme.disabledOpacity)
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
  /// Its name among the inspector's stops, when it is in the inspector.
  var stop: String?
  /// In its hairline frame, as in a form; unframed, as the inspector's quiet
  /// values are drawn — the date as text, with a hover fill.
  var framed = true
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
    Group {
      if framed {
        Button { isPicking.toggle() } label: {
          Label(title, systemImage: "calendar")
            .labelStyle(.titleAndIcon)
            .monospacedDigit()
            .lineLimit(1)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .themedControlFrame()
      } else {
        Button { isPicking.toggle() } label: {
          Text(title).monospacedDigit()
        }
        .buttonStyle(InspectorValueButtonStyle())
        .fixedSize()
      }
    }
    .inspectorStop(stop ?? "date", press: { isPicking.toggle() })
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
          // The chip style draws no default-button tint, so the tooltip is
          // what says Return closes it.
          Button("Done") { isPicking = false }
            .keyboardShortcut(.defaultAction)
            .help("Done · ↩")
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

/// A tag: a squarish rectangle at the control radius, never a capsule, in the
/// caption face. Tinted, it is the status convention — fill, border and text
/// of one hue at the status opacities; untinted, it is a quiet well with a
/// hairline, for a plain label such as a name or a file's origin.
///
/// The same geometry as `FocusChipButtonStyle`, so a tag beside a chip reads
/// as the same kind of thing that happens not to be pressable.
struct ThemedTag: View {
  @Environment(\.theme) private var theme
  let text: String
  var tint: Color?

  init(_ text: String, tint: Color? = nil) {
    self.text = text
    self.tint = tint
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
    Text(text)
      .font(theme.captionFont)
      .foregroundStyle(tint ?? theme.muted)
      .lineLimit(1)
      .padding(.horizontal, theme.space.sm)
      .padding(.vertical, theme.space.xxs)
      .background(shape.fill(tint.map { $0.opacity(Theme.statusFillOpacity) } ?? theme.well))
      .overlay(
        shape.strokeBorder(
          tint.map { $0.opacity(Theme.statusBorderOpacity) } ?? theme.border, lineWidth: theme.hairline))
  }
}
