import AppKit
import SwiftUI

/// The agent panel's message field: a few lines of wrapping text where
/// Return sends and Shift-Return starts a new line.
///
/// An `NSTextView` rather than a SwiftUI `TextEditor`, for the reason the
/// title bar's add field is an `NSTextField`: its keys are answered in
/// `doCommandBy`, which sees Return, Escape and Tab before the text view acts
/// on them, and `makeFirstResponder` takes the keyboard when asked where
/// `@FocusState` cannot be relied on to. It is also an `NSTextView`, which is
/// what the window's key monitor looks for to leave typing alone.
struct WorkspaceAgentInputField: NSViewRepresentable {
  @Binding var text: String
  let focusRequest: Int
  let font: NSFont
  let textColor: NSColor
  let insertionColor: NSColor
  let onSubmit: () -> Void
  let onCancel: () -> Void
  /// Tab: the pending approval card, if there is one. Returns whether it
  /// took the key; otherwise Tab leaves the field as it would anywhere.
  let onTab: () -> Bool
  let onFocusChange: (Bool) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder

    let textView = FocusReportingTextView()
    textView.delegate = context.coordinator
    textView.onFocusChange = { [weak coordinator = context.coordinator] focused in
      coordinator?.parent.onFocusChange(focused)
    }
    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.drawsBackground = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    scroll.documentView = textView
    context.coordinator.lastFocusRequest = focusRequest
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let textView = scroll.documentView as? NSTextView else { return }
    if textView.font != font { textView.font = font }
    if textView.textColor != textColor { textView.textColor = textColor }
    if textView.insertionPointColor != insertionColor { textView.insertionPointColor = insertionColor }
    textView.typingAttributes = [.font: font, .foregroundColor: textColor]
    if textView.string != text { textView.string = text }
    if context.coordinator.lastFocusRequest != focusRequest {
      context.coordinator.lastFocusRequest = focusRequest
      DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
    }
  }

  /// Says when it gains and loses the keyboard. The delegate only hears
  /// about editing once something is typed, which is too late to light the
  /// ring or to tell the window whose keys these are.
  final class FocusReportingTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
      let became = super.becomeFirstResponder()
      if became { onFocusChange?(true) }
      return became
    }

    override func resignFirstResponder() -> Bool {
      let resigned = super.resignFirstResponder()
      if resigned { onFocusChange?(false) }
      return resigned
    }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: WorkspaceAgentInputField
    var lastFocusRequest = 0
    init(_ parent: WorkspaceAgentInputField) { self.parent = parent }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      parent.text = textView.string
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      switch selector {
      case #selector(NSResponder.insertNewline(_:)):
        // Shift-Return is a new line, as in the notes overlay. Plain Return
        // sends.
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
          textView.insertNewlineIgnoringFieldEditor(nil)
        } else {
          parent.onSubmit()
        }
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        parent.onCancel()
        return true
      case #selector(NSResponder.insertTab(_:)):
        if parent.onTab() { return true }
        textView.window?.selectNextKeyView(nil)
        return true
      default:
        return false
      }
    }
  }
}
