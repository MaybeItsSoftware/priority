import AppKit
import TaktCore
import TaktWorkspace
import SwiftUI

/// A new task, typed where it will be.
///
/// Return (or ⌘N, ⇧Return, ⌥⇧Return) opens this row at the place the task
/// lands — below the task you are on, above it, inside it, or at the end of
/// the pane — rather than in a field in the title bar that only named the
/// place. Return files it and leaves a fresh row under the one just made, so
/// a run of tasks is typed straight down, the way Checkvist does it. Esc, or
/// leaving the row empty, closes it; ↑ and ↓ close it and move on through the
/// tasks from where it sat.
///
/// The text is the model's (`taskDraftText`), not the row's: the row is
/// rebuilt whenever the task it sits beside changes or leaves the pane, and
/// a rebuilt row takes up the title, caret and keyboard where the last one
/// left them.
struct WorkspaceTaskDraftRow: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  /// How far in it sits, in outline steps. Zero outside the outline.
  var depth = 0
  /// Whether to say which list it goes to: only where the row's position
  /// does not already say so, like a day or a quadrant drawn from many lists.
  var namesDestination = false
  /// Drawn as one of the board's cards rather than an outline row: square,
  /// edge to edge between hairlines, and with no glyph column, since a card
  /// has none for its title to line up after.
  var isCard = false

  @FocusState private var isFocused: Bool
  /// Set while the row is taking the keyboard itself, so the caret goes back
  /// where it was rather than where AppKit's select-all on focus puts it. A
  /// click into the field places its own caret and is left alone.
  @State private var restoresCaret = false

  var body: some View {
    @Bindable var model = model
    let capture = TaskCapture.parse(model.taskDraftText)
    HStack(spacing: theme.space.sm) {
      // The glyph column left empty, so the text starts where a task's title
      // does; the ring around the row is what says it is a place to type.
      if !isCard {
        Color.clear
          .frame(width: WorkspaceRowMetrics.iconWidth, height: 1)
      }
      TextField("New task", text: $model.taskDraftText)
        .textFieldStyle(.plain)
        .foregroundStyle(theme.ink)
        .focused($isFocused)
        .onSubmit(submit)
        .onExitCommand { model.endTaskDraft() }
        // Checkvist's indent while typing: Tab puts the new task inside the
        // one above it, ⇧Tab back out to that task's level.
        .onKeyPress(.tab, phases: .down) { press in
          if press.modifiers.contains(.shift) {
            model.outdentTaskDraft()
          } else {
            model.indentTaskDraft()
          }
          return .handled
        }
        // The arrows leave the row and carry on through the tasks, so
        // stepping away from a draft is the same keys as stepping anywhere.
        .onKeyPress(keys: [.upArrow, .downArrow], phases: .down) { press in
          guard press.modifiers.isDisjoint(with: [.command, .option, .control, .shift]) else { return .ignored }
          model.leaveTaskDraft(by: press.key == .upArrow ? -1 : 1)
          return .handled
        }
      if capture.hasDetails {
        TaskCapturePreview(capture: capture)
          .font(theme.monoCaptionFont)
      }
      if namesDestination {
        Text(model.addFieldDestinationTitle)
          .font(theme.monoCaptionFont)
          .foregroundStyle(theme.dim)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .font(theme.bodyFont())
    .modifier(DraftChrome(isCard: isCard, depth: depth))
    .help(keysHint)
    .onAppear { focusSoon() }
    .onChange(of: model.taskComposerFocusRequest) { _, _ in focusSoon() }
    .onChange(of: isFocused) { _, focused in
      guard focused, restoresCaret else { return }
      restoresCaret = false
      restoreCaret()
    }
    .onChange(of: model.taskDraftText) { _, _ in noteCaret() }
    // The row going — rebuilt beside another task — keeps the caret for the
    // next one, arrow-key moves included, which no text change recorded.
    .onDisappear { noteCaret() }
  }

  /// The row's own keys, ahead of the capture syntax, in the tooltip rather
  /// than along the row: a hint line under every draft would be one more row
  /// in a list of tasks. Tab only means something in the outline.
  private var keysHint: String {
    var keys = ["↩ add", "esc close"]
    if model.viewMode == .outline { keys.append("⇥ ⇧⇥ indent, outdent") }
    keys.append("↑ ↓ back to the tasks")
    return "\(keys.joined(separator: " · ")). \(TaskCapturePreview.syntaxHint)"
  }

  /// A beat late, so the row is in the window — inside a `List` it is not
  /// yet when `onAppear` runs, and the focus would be dropped.
  private func focusSoon() {
    DispatchQueue.main.async {
      guard !isFocused else { return }
      restoresCaret = true
      isFocused = true
    }
  }

  /// The field editor while this row has the keyboard, and nil otherwise:
  /// it is the window's one shared text view, so whose it is matters.
  private var fieldEditor: NSTextView? {
    guard isFocused else { return nil }
    return NSApp.keyWindow?.firstResponder as? NSTextView
  }

  private func noteCaret() {
    guard let editor = fieldEditor, editor.string == model.taskDraftText else { return }
    model.taskDraftSelection = editor.selectedRange()
  }

  /// Puts the caret back where it was before the row was rebuilt — at the
  /// end of the text when nothing was noted — rather than leaving the whole
  /// title selected for the next key to replace.
  private func restoreCaret() {
    let length = (model.taskDraftText as NSString).length
    guard length > 0 else { return }
    let saved = model.taskDraftSelection ?? NSRange(location: length, length: 0)
    let location = min(saved.location, length)
    let range = NSRange(location: location, length: min(saved.length, length - location))
    // A beat late again: the field selects its text as it takes the
    // keyboard, after this change is delivered.
    DispatchQueue.main.async {
      guard let editor = fieldEditor, editor.string == model.taskDraftText else { return }
      editor.setSelectedRange(range)
    }
  }

  private func submit() {
    let text = model.taskDraftText
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      model.endTaskDraft()
      return
    }
    model.taskDraftText = ""
    model.taskDraftSelection = nil
    model.submitAddField(named: text)
    // The row may be rebuilt under the new task; ask again so it keeps the key.
    model.taskComposerFocusRequest += 1
  }
}

/// The draft's frame: a ringed outline row, or a card with the keyboard on it.
private struct DraftChrome: ViewModifier {
  @Environment(\.theme) private var theme
  let isCard: Bool
  let depth: Int

  func body(content: Content) -> some View {
    if isCard {
      // The same band a selected card draws, between the same rules, so the
      // card being typed reads as the card it will become.
      content
        .padding(.vertical, theme.space.xs)
        .padding(.horizontal, WorkspaceBoardMetrics.columnPadding(theme))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
          ZStack {
            Rectangle().fill(theme.paper)
            WorkspaceSelectionBackground(isSelected: true, hasKeyboard: true)
          }
        }
        .overlay {
          VStack(spacing: 0) {
            FocusRule()
            Spacer(minLength: 0)
            FocusRule()
          }
          .allowsHitTesting(false)
        }
    } else {
      // Drawn as the row with the keyboard: a ring, not a fill, so it reads
      // as a place to type rather than one more task.
      content
        .padding(.leading, CGFloat(depth) * WorkspaceRowMetrics.indent(theme))
        .padding(.vertical, theme.rowVerticalPadding)
        .padding(.horizontal, theme.paneGutter)
        .overlay(
          RoundedRectangle(cornerRadius: theme.controlRadius)
            .strokeBorder(theme.focusRing, lineWidth: theme.focusRingWidth)
            .padding(.horizontal, theme.space.xs))
    }
  }
}
