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

  @State private var title = ""
  @FocusState private var isFocused: Bool

  var body: some View {
    let capture = TaskCapture.parse(title)
    HStack(spacing: theme.space.sm) {
      // The glyph column left empty, so the text starts where a task's title
      // does; the ring around the row is what says it is a place to type.
      if !isCard {
        Color.clear
          .frame(width: WorkspaceRowMetrics.iconWidth, height: 1)
      }
      TextField("New task", text: $title)
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
