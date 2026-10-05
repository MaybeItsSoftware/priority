import AppKit
import TaktCore
import TaktWorkspace
import SwiftUI

/// Quick capture's field, in the title bar.
///
/// Only while quick capture runs. Every other new task is typed in a draft
/// row at the place it will land (`WorkspaceTaskDraftRow`); a capture is the
/// one add that is not into the list on screen — the arrows send it
/// elsewhere, up and down for the list and left and right for the day it
/// starts — so it keeps a field that names its destination instead.
struct WorkspaceTitleBarAddField: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  @State private var title = ""
  @State private var isEditing = false

  /// Room for a sentence and a list name without crowding the mode strip.
  static let width: CGFloat = 320
  /// The destination's share of the field, so a long list name truncates
  /// rather than squeezing the text you are typing.
  static let destinationWidth: CGFloat = 120
  /// The destination's share while the capture preview shows. The chips can
  /// run to four, and at the full share they and the list name would leave
  /// the text itself no room; the name still reads, truncated, beside them.
  static let compactDestinationWidth: CGFloat = 64

  var body: some View {
    if model.isQuickCaptureActive { field }
  }

  private var field: some View {
    HStack(spacing: theme.space.xs) {
      Image(systemName: "tray.and.arrow.down")
        .font(theme.captionFont)
        .foregroundStyle(isEditing ? theme.primary : theme.muted)
      TitleBarAddTextField(
        text: $title,
        isEditing: $isEditing,
        focusRequest: model.quickCaptureFocusRequest,
        font: Self.fieldFont(theme),
        textColor: NSColor(theme.ink),
        placeholderColor: NSColor(theme.dim),
        onSubmit: submit,
        onCancel: cancel,
        onEndEditing: { model.taskInsertionReference = nil },
        onArrow: arrow)
      trailing
    }
    .padding(.horizontal, theme.space.sm)
    .padding(.vertical, theme.space.xxs)
    .frame(width: Self.width)
    // An input on the page: a hairline, no fill, the ring while it has the
    // keyboard.
    .overlay(
      RoundedRectangle(cornerRadius: theme.controlRadius)
        .strokeBorder(
          isEditing ? theme.focusRing : theme.inputBorder,
          lineWidth: isEditing ? theme.focusRingWidth : theme.hairline))
    .commandHelp(
      .taskNew,
      note: "Add a task to \(model.addFieldDestinationTitle). \(TaskCapturePreview.syntaxHint)")
  }

  @ViewBuilder
  private var trailing: some View {
    let capture = TaskCapture.parse(title)
    HStack(spacing: theme.space.xs) {
      // What Return will file beyond the title, shown before it is pressed:
      // the parse only reads trailing words, and seeing it is what makes a
      // bare `30m` safe to accept without a prefix.
      if capture.hasDetails {
        TaskCapturePreview(capture: capture)
      }
      if model.isQuickCaptureActive {
        Text(model.quickCaptureStartLabel)
          .foregroundStyle(theme.muted)
          .help("← → the day it starts")
      }
      destination(width: capture.hasDetails ? Self.compactDestinationWidth : Self.destinationWidth)
      // Only for an empty, idle field, which never has chips, so the keycap
      // and the preview never compete for the field's fixed width.
      if !isEditing, title.isEmpty {
        KeyCap(WorkspaceCommandHelpText.firstKey(for: .taskNew))
      }
    }
    .font(theme.monoFont(size: theme.type.microLabel.size))
    .lineLimit(1)
    .fixedSize(horizontal: false, vertical: true)
  }

  /// The destination, and in a folder the menu that changes it — the one
  /// scope with more than one list a task could honestly go to.
  @ViewBuilder
  private func destination(width: CGFloat) -> some View {
    let label = Text(model.addFieldDestinationTitle)
      .foregroundStyle(isEditing ? theme.ink : theme.muted)
      .truncationMode(.tail)
      .frame(maxWidth: width, alignment: .trailing)
    if model.selectedFolderID != nil && model.taskInsertionReference == nil && !model.isQuickCaptureActive {
      Menu {
        ForEach(model.scopeLists) { list in
          Button(list.name) { model.newTaskListID = list.id }
        }
      } label: {
        label
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .commandHelp(.listNewTaskDestination, note: "Choose which of the folder's lists new tasks go to")
    } else {
      label
        .help(model.isQuickCaptureActive ? "↑ ↓ the list it goes to" : model.addFieldDestinationTitle)
    }
  }

  private func submit() {
    let text = title
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    title = ""
    model.submitAddField(named: text)
  }

  private func cancel() {
    title = ""
    model.cancelAddField()
  }

  /// Arrows steer quick capture; anywhere else they are the field's own.
  private func arrow(_ direction: TitleBarAddTextField.Arrow) -> Bool {
    guard model.isQuickCaptureActive else { return false }
    switch direction {
    case .up: model.moveQuickCaptureDestination(by: -1)
    case .down: model.moveQuickCaptureDestination(by: 1)
    case .left: model.moveQuickCaptureStartDay(by: -1)
    case .right: model.moveQuickCaptureStartDay(by: 1)
    }
    return true
  }

  /// The theme's body face as AppKit needs it, for a field that has to be an
  /// `NSTextField`. `Theme.nsFont` resolves it exactly as `Theme.font` does
  /// for SwiftUI, so the field and the rows below it are the same face.
  static func fieldFont(_ theme: Theme) -> NSFont {
    Theme.nsFont(theme.type.body, size: theme.scale.body)
  }
}

/// An `NSTextField` rather than a SwiftUI one, for two reasons. It sits in a
/// toolbar item's hosting view, where `@FocusState` cannot be relied on to
/// take the keyboard from the window's content — `makeFirstResponder` can.
/// And its arrows are answered through `doCommandBy`, which sees them before
/// the field editor turns them into cursor movement.
struct TitleBarAddTextField: NSViewRepresentable {
  enum Arrow { case up, down, left, right }

  @Binding var text: String
  @Binding var isEditing: Bool
  let focusRequest: Int
  let font: NSFont
  let textColor: NSColor
  let placeholderColor: NSColor
  let onSubmit: () -> Void
  let onCancel: () -> Void
  /// Clicking away, as opposed to Escape: the text stays, but a placement
  /// taken from the task the cursor was on does not outlive the moment.
  let onEndEditing: () -> Void
  let onArrow: (Arrow) -> Bool

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> Field {
    let field = Field()
    field.onFocus = { [weak coordinator = context.coordinator] in coordinator?.parent.isEditing = true }
    field.delegate = context.coordinator
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.lineBreakMode = .byTruncatingTail
    field.cell?.usesSingleLineMode = true
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    // One behind, so the first update takes the keyboard: the field is only
    // built when quick capture starts, which is exactly when it should.
    context.coordinator.lastFocusRequest = focusRequest - 1
    return field
  }

  func updateNSView(_ field: Field, context: Context) {
    context.coordinator.parent = self
    if field.font != font { field.font = font }
    if field.textColor != textColor { field.textColor = textColor }
    if field.stringValue != text { field.stringValue = text }
    let placeholder = NSAttributedString(
      string: "Add a task", attributes: [.foregroundColor: placeholderColor, .font: font])
    if field.placeholderAttributedString != placeholder { field.placeholderAttributedString = placeholder }
    if context.coordinator.lastFocusRequest != focusRequest {
      context.coordinator.lastFocusRequest = focusRequest
      DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
    }
  }

  /// Says when it takes the keyboard. The delegate only hears about editing
  /// once the first character is typed, which is too late to light the ring.
  final class Field: NSTextField {
    var onFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
      let became = super.becomeFirstResponder()
      if became { onFocus?() }
      return became
    }
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: TitleBarAddTextField
    var lastFocusRequest = 0
    init(_ parent: TitleBarAddTextField) { self.parent = parent }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      parent.text = field.stringValue
    }

    func controlTextDidEndEditing(_ notification: Notification) {
      parent.isEditing = false
      parent.onEndEditing()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      switch selector {
      case #selector(NSResponder.insertNewline(_:)):
        parent.onSubmit()
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        parent.onCancel()
        return true
      case #selector(NSResponder.moveUp(_:)): return parent.onArrow(.up)
      case #selector(NSResponder.moveDown(_:)): return parent.onArrow(.down)
      case #selector(NSResponder.moveLeft(_:)): return parent.onArrow(.left)
      case #selector(NSResponder.moveRight(_:)): return parent.onArrow(.right)
      default: return false
      }
    }
  }
}

/// What a typed task will be filed with beyond its title — `45m`, `Fri 2 Oct`,
/// `#work`, `!1` — shown as the field is typed, so the trailing-word parse in
/// `TaskCapture` is never a surprise after Return.
///
/// Each label is a status chip in the house convention: a tinted fill, a
/// hairline of the same hue and text in it, squarish rather than a pill. The
/// hue is the primary one because this is information, not a warning.
struct TaskCapturePreview: View {
  @Environment(\.theme) private var theme
  let capture: TaskCapture

  /// One sentence on the syntax, for the tooltips of the places that parse it.
  static let syntaxHint =
    "End it with 30m, @fri, #tag or !1 to set its estimate, due day, tags or priority."

  var body: some View {
    let labels = capture.detailLabels()
    HStack(spacing: theme.space.xxs) {
      ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
        Text(label)
          .font(theme.monoFont(size: theme.type.microLabel.size))
          .foregroundStyle(theme.primary)
          .lineLimit(1)
          .padding(.horizontal, theme.space.xxs)
          .background(
            RoundedRectangle(cornerRadius: theme.controlRadius)
              .fill(theme.color(.primary, opacity: Theme.statusFillOpacity)))
          .overlay(
            RoundedRectangle(cornerRadius: theme.controlRadius)
              .strokeBorder(theme.color(.primary, opacity: Theme.statusBorderOpacity), lineWidth: theme.hairline))
      }
    }
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Will set \(labels.joined(separator: ", "))")
  }
}
