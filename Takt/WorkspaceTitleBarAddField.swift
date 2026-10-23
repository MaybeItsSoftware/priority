import AppKit
import TaktCore
import TaktWorkspace
import SwiftUI

/// Quick capture's field, in the window the global hotkey brings up
/// (`QuickCapturePanelController`). It used to sit in the title bar.
///
/// Only while quick capture runs. Every other new task is typed in a draft
/// row at the place it will land (`WorkspaceTaskDraftRow`); a capture is the
/// one add that is not into the list on screen — up and down send it to
/// another list — so the window lists where it can go under the field.
///
/// Drawn as the overlays' field row (`WorkspaceOverlayField`) is — a glyph,
/// the text in the body face, no box of its own — because the window it sits
/// in is drawn as an overlay is, and the chips after the text are the draft
/// row's, so a capture says what it will set exactly as a task typed in the
/// window does. To the right of those, the slots (`TaskEntrySlotStrip`):
/// → at the end of the text walks into the due day, the conditions and the
/// estimate, which the window around it drives while they have the keys.
struct WorkspaceTitleBarAddField: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  @Binding var title: String
  @Binding var slots: TaskEntryDraft
  /// Moves on whenever the keyboard comes back to the text from a slot, so
  /// the field takes it with the caret at the end.
  let textFocusRequest: Int
  let onSubmit: () -> Void
  let onCancel: () -> Void
  @State private var isEditing = false

  var body: some View {
    if model.isQuickCaptureActive { field }
  }

  private var field: some View {
    let capture = TaskCapture.parse(title)
    // The slots run the bar's full height to its right edge, ruled off as
    // cells; only the title side keeps the row's padding.
    return HStack(spacing: 0) {
      HStack(spacing: theme.space.sm) {
        Image(systemName: "tray.and.arrow.down")
          .foregroundStyle(theme.muted)
        TitleBarAddTextField(
          text: $title,
          isEditing: $isEditing,
          focusRequest: model.quickCaptureFocusRequest + textFocusRequest,
          holdsKeyboard: !slots.focus.isSlot,
          font: Self.fieldFont(theme),
          textColor: NSColor(theme.ink),
          placeholderColor: NSColor(theme.dim),
          onSubmit: onSubmit,
          onCancel: onCancel,
          onEndEditing: { model.taskInsertionReference = nil },
          onArrow: arrow,
          // A click into the text takes the keys back from a slot.
          onFocus: { if slots.focus.isSlot { slots.focus = .text } })
        // What Return will file beyond the title, shown before it is pressed:
        // the parse only reads trailing words, and seeing it is what makes a
        // bare `30m` safe to accept without a prefix.
        if capture.hasDetails {
          TaskCapturePreview(capture: capture)
        }
      }
      .padding(.leading, theme.listGutter)
      .padding(.trailing, theme.space.sm)
      .padding(.vertical, theme.space.sm)
      TaskEntrySlotStrip(slots: $slots)
    }
    .fixedSize(horizontal: false, vertical: true)
    .font(theme.bodyFont())
    .commandHelp(
      .taskNew,
      note: "Add a task to \(model.addFieldDestinationTitle). \(TaskCapturePreview.syntaxHint)")
  }

  /// Up and down steer quick capture to another list; → at the end of the
  /// text, or Tab, walks into the slots. ← is the caret's.
  private func arrow(_ direction: TitleBarAddTextField.Arrow) -> Bool {
    guard model.isQuickCaptureActive else { return false }
    switch direction {
    case .up: model.moveQuickCaptureDestination(by: -1)
    case .down: model.moveQuickCaptureDestination(by: 1)
    case .left: return false
    case .right: slots.focus = .date
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
  /// False while one of the slots beside it has the keys: the field lets
  /// go of them, so its caret stops blinking at text the keys are not in.
  var holdsKeyboard = true
  let font: NSFont
  let textColor: NSColor
  let placeholderColor: NSColor
  let onSubmit: () -> Void
  let onCancel: () -> Void
  /// Clicking away, as opposed to Escape: the text stays, but a placement
  /// taken from the task the cursor was on does not outlive the moment.
  let onEndEditing: () -> Void
  let onArrow: (Arrow) -> Bool
  var onFocus: () -> Void = {}

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> Field {
    let field = Field()
    field.onFocus = { [weak coordinator = context.coordinator] in
      coordinator?.parent.isEditing = true
      coordinator?.parent.onFocus()
    }
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
      string: "New task", attributes: [.foregroundColor: placeholderColor, .font: font])
    if field.placeholderAttributedString != placeholder { field.placeholderAttributedString = placeholder }
    if context.coordinator.lastFocusRequest != focusRequest {
      context.coordinator.lastFocusRequest = focusRequest
      DispatchQueue.main.async {
        guard field.window?.makeFirstResponder(field) == true else { return }
        // The caret at the end, not the whole title selected: coming back
        // from a slot, the next key carries on the title.
        let end = (field.stringValue as NSString).length
        field.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
      }
    }
    if !holdsKeyboard, field.currentEditor() != nil {
      DispatchQueue.main.async { field.window?.makeFirstResponder(nil) }
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
      case #selector(NSResponder.insertTab(_:)): return parent.onArrow(.right)
      // ⌘⌫ takes back a word, as ⌥⌫ does, rather than the whole line: a
      // capture is one line, so "to the start of the line" was everything.
      case #selector(NSResponder.deleteToBeginningOfLine(_:)):
        textView.deleteWordBackward(nil)
        return true
      // Left and right move the caret, as they do in the window's own add
      // row; only where the caret can go no further do they steer — → at
      // the end into the slots.
      case #selector(NSResponder.moveLeft(_:)):
        let selection = textView.selectedRange()
        guard selection.length == 0, selection.location == 0 else { return false }
        return parent.onArrow(.left)
      case #selector(NSResponder.moveRight(_:)):
        let selection = textView.selectedRange()
        guard selection.length == 0, selection.location == (textView.string as NSString).length else { return false }
        return parent.onArrow(.right)
      default: return false
      }
    }
  }
}

/// What a typed task will be filed with beyond its title — `45m`, `starts
/// Mon 5 Oct`, `due Fri 9 Oct`, `#work`, `!1` — shown as the field is typed,
/// so the trailing-word parse in `TaskCapture` is never a surprise after
/// Return.
///
/// Each label is plain text in the mono face, as the slots' values are, in
/// the primary hue because it is information, not a warning. No box: the
/// strip after it already rules off the fields. The one warning — a start
/// on or after the due day, which Return will not file — follows them in
/// the danger hue, in the editor's words.
struct TaskCapturePreview: View {
  @Environment(\.theme) private var theme
  let capture: TaskCapture

  /// One sentence on the syntax, for the tooltips of the places that parse it.
  static let syntaxHint =
    "End it with 30m, @fri, ^mon, #tag or !1 to set its estimate, due day, start day, tags or priority."

  var body: some View {
    let labels = capture.detailLabels()
    HStack(spacing: theme.space.sm) {
      ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
        Text(label)
          .font(InlineField<EmptyView>.font(theme))
          .foregroundStyle(theme.primary)
          .lineLimit(1)
      }
      if let problem = capture.problem {
        Text(problem)
          .font(InlineField<EmptyView>.font(theme))
          .foregroundStyle(theme.danger)
          .lineLimit(1)
      }
    }
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      ["Will set \(labels.joined(separator: ", "))", capture.problem].compactMap { $0 }.joined(separator: ". "))
  }
}
