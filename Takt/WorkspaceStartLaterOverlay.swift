import SwiftUI
import TaktCore
import TaktWorkspace

/// A save that starts a task on a later day while it has a deadline, held
/// until the person says what the deadline does (`TaskStartLater`).
struct WorkspaceStartLaterRequest: Identifiable {
  let id = UUID()
  let taskTitle: String
  let asked: TaskStartLater
  /// The edit being saved, before the answer is put into it.
  let draft: TaskEditorDraft
  /// Carries on with the edit as answered, and whether to keep the deadline.
  let proceed: @MainActor (TaskEditorDraft, Bool) -> Void
  /// Puts the edit back in front of the person, where there is somewhere to put it.
  var cancel: (@MainActor () -> Void)?
}

@MainActor
extension WorkspaceViewModel {
  /// Asks what happens to the deadline when saving `draft` starts the task
  /// on a later day. Returns whether it asked: if so the caller saves
  /// nothing, and `proceed` carries the edit on once the person has answered.
  func askAboutStartingLater(
    _ draft: TaskEditorDraft, title: String,
    proceed: @escaping @MainActor (TaskEditorDraft, Bool) -> Void,
    cancel: (@MainActor () -> Void)? = nil
  ) -> Bool {
    guard let asked = TaskStartLater.check(draft) else { return false }
    presentOverlay(.startLater(WorkspaceStartLaterRequest(
      taskTitle: title, asked: asked, draft: draft, proceed: proceed, cancel: cancel)))
    return true
  }

  func resolveStartLater(_ request: WorkspaceStartLaterRequest, choice: StartLaterChoice) {
    dismissOverlay()
    guard choice.saves else {
      request.cancel?()
      return
    }
    var draft = request.draft
    let keepingDue = request.asked.apply(choice, to: &draft.values)
    request.proceed(draft, keepingDue)
  }
}

/// The deadline's ways out, as rows: ↩ takes the first, 1–3 a row by its
/// number, and escape — the host's — cancels.
struct WorkspaceStartLaterOverlay: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let overlayID: String
  let request: WorkspaceStartLaterRequest
  @State private var selection = 0

  private var choices: [StartLaterChoice] { request.asked.choices }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: theme.space.xxs) {
        Text("Starting \(TaskStartLater.text(request.asked.start, withTime: false)): what about the due date?")
          .font(theme.bodyFont().weight(.semibold))
          .foregroundStyle(theme.ink)
        Text(message)
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
      }
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, theme.listGutter)
      .padding(.vertical, theme.space.sm)
      FocusRule()
      ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
        Button {
          model.resolveStartLater(request, choice: choice)
        } label: {
          HStack(spacing: theme.space.sm) {
            Text(choice.title).foregroundStyle(choice == .cancel ? theme.muted : theme.ink)
            if let due = request.asked.dueText(for: choice) {
              Text("Due \(due)").font(theme.captionFont).foregroundStyle(theme.dim)
            }
            Spacer()
            Text(key(for: choice, at: index)).font(theme.monoCaptionFont).foregroundStyle(theme.dim)
          }
          .overlayRow(isSelected: index == selection)
        }
        .buttonStyle(.plain)
      }
      WorkspaceOverlayFooter(hints: "↑↓ choose · ↩ pick · 1–\(choices.count - 1) by number · esc cancel")
    }
    .overlayKeys(model, id: overlayID) { key in
      if let offset = WorkspaceOverlayStep.offset(for: key) {
        selection = WorkspaceOverlayStep.index(from: selection, by: offset, count: choices.count) ?? 0
        return true
      }
      if key == "enter" {
        model.resolveStartLater(request, choice: choices[selection])
      } else if let number = Int(key), (1..<choices.count).contains(number) {
        model.resolveStartLater(request, choice: choices[number - 1])
      }
      // Nothing behind it takes a key while it is up.
      return true
    }
  }

  /// Why it asks: when the deadline is, and, when it falls before the new
  /// start, that it can't stay there.
  private var message: String {
    let due = TaskStartLater.text(request.asked.due, withTime: !request.asked.dueIsDay)
    let start = TaskStartLater.text(request.asked.start, withTime: false)
    return request.asked.canKeep
      ? "“\(request.taskTitle)” is due \(due)."
      : "“\(request.taskTitle)” is due \(due), before it would start on \(start), so the due date can't stay."
  }

  private func key(for choice: StartLaterChoice, at index: Int) -> String {
    switch choice {
    case .cancel: "esc"
    default: index == 0 ? "1 ↩" : "\(index + 1)"
    }
  }
}
