import AppKit
import PriorityCore
import PriorityWorkspace
import SwiftUI

/// Add a task, from the title bar.
///
/// The window's one place to type a new task, beside the mode strip in the
/// bar you drag the window by. It names where the task will land — the list
/// on screen, the task `a` was pressed on, or the inbox — so Return is never
/// a guess. See `WorkspaceViewModel+AddTask` for the rule.
///
/// While quick capture is running the same field takes the arrows: up and
/// down choose the list, left and right the day it starts. Outside it the
/// arrows move the cursor as in any other field.
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

  var body: some View {
    HStack(spacing: theme.space.xs) {
      Image(systemName: model.isQuickCaptureActive ? "tray.and.arrow.down" : "plus")
        .font(theme.captionFont)
        .foregroundStyle(isEditing ? theme.primary : theme.muted)
      TitleBarAddTextField(
        text: $title,
        isEditing: $isEditing,
        focusRequest: model.taskComposerFocusRequest,
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
    .commandHelp(.taskNew, note: "Add a task to \(model.addFieldDestinationTitle)")
  }

  @ViewBuilder
  private var trailing: some View {
    HStack(spacing: theme.space.xs) {
      if model.isQuickCaptureActive {
        Text(model.quickCaptureStartLabel)
          .foregroundStyle(theme.muted)
          .help("← → the day it starts")
      }
      destination
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
  private var destination: some View {
    let label = Text(model.addFieldDestinationTitle)
      .foregroundStyle(isEditing ? theme.ink : theme.muted)
      .truncationMode(.tail)
      .frame(maxWidth: Self.destinationWidth, alignment: .trailing)
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
  /// `NSTextField`. Resolved the way `Theme.font` resolves it: the named
  /// families if one is installed, the design otherwise.
  static func fieldFont(_ theme: Theme) -> NSFont {
    let size = theme.scale.body
    let face = theme.type.body
    if let name = face.families.first(where: { NSFont(name: $0, size: size) != nil }),
      let font = NSFont(name: name, size: size) {
      return font
    }
    let system = NSFont.systemFont(ofSize: size)
    let design: NSFontDescriptor.SystemDesign
    switch face.design {
    case .serif: design = .serif
    case .monospaced: design = .monospaced
    case .rounded: design = .rounded
    case .sans: design = .default
    }
    return system.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? system
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
    context.coordinator.lastFocusRequest = focusRequest
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
