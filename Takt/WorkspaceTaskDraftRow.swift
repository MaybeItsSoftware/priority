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
/// leaving the row empty, closes it.
struct WorkspaceTaskDraftRow: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  /// How far in it sits, in outline steps. Zero outside the outline.
  var depth = 0
  /// Whether to say which list it goes to: only where the row's position
  /// does not already say so, like a day or a quadrant drawn from many lists.
  var namesDestination = false

  @State private var title = ""
  @FocusState private var isFocused: Bool

  var body: some View {
    let capture = TaskCapture.parse(title)
    HStack(spacing: theme.space.sm) {
      // The glyph column left empty, so the text starts where a task's title
      // does; the ring around the row is what says it is a place to type.
      Color.clear
        .frame(width: WorkspaceRowMetrics.iconWidth, height: 1)
      TextField("New task", text: $title)
        .textFieldStyle(.plain)
        .foregroundStyle(theme.ink)
        .focused($isFocused)
        .onSubmit(submit)
        .onExitCommand { model.endTaskDraft() }
        // Checkvist's indent while typing: Tab puts the new task inside the
        // one above it, ⇧Tab back out to that task's level.
        .onKeyPress(.tab, phases: .down) { press in
          press.modifiers.contains(.shift) ? model.outdentTaskDraft() : model.indentTaskDraft()
          return .handled
        }
      if capture.hasDetails {
        TaskCapturePreview(capture: capture)
          .font(theme.monoFont(size: theme.type.microLabel.size))
      }
      if namesDestination {
        Text(model.addFieldDestinationTitle)
          .font(theme.monoFont(size: theme.type.microLabel.size))
          .foregroundStyle(theme.dim)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .font(theme.bodyFont())
    .padding(.leading, CGFloat(depth) * WorkspaceRowMetrics.indent(theme))
    .padding(.vertical, theme.rowVerticalPadding)
    .padding(.horizontal, theme.paneGutter)
    // Drawn as the row with the keyboard: a ring, not a fill, so it reads as
    // a place to type rather than one more task.
    .overlay(
      RoundedRectangle(cornerRadius: theme.controlRadius)
        .strokeBorder(theme.focusRing, lineWidth: theme.focusRingWidth)
        .padding(.horizontal, theme.space.xs))
    .help(TaskCapturePreview.syntaxHint)
    .onAppear { focusSoon() }
    .onChange(of: model.taskComposerFocusRequest) { _, _ in focusSoon() }
  }

  /// A beat late, so the row is in the window — inside a `List` it is not
  /// yet when `onAppear` runs, and the focus would be dropped.
  private func focusSoon() {
    DispatchQueue.main.async { isFocused = true }
  }

  private func submit() {
    let text = title
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      model.endTaskDraft()
      return
    }
    title = ""
    model.submitAddField(named: text)
    // The row may be rebuilt under the new task; ask again so it keeps the key.
    model.taskComposerFocusRequest += 1
  }
}
