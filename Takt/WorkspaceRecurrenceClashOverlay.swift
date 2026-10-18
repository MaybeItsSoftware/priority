import SwiftUI
import TaktCore
import TaktWorkspace

/// A save that moves a repeating task onto or past the day it comes round
/// again anyway, held until the person says what should happen. The Rust
/// core decides it is a clash (`WorkspaceStore.recurrenceClash(for:)`).
struct WorkspaceRecurrenceClashRequest: Identifiable {
  let id = UUID()
  let taskTitle: String
  let clash: TaskRecurrenceClash
  /// The edit being saved; "Keep both" copies its dates.
  let draft: TaskEditorDraft
  /// Saves the move. False when it failed, which it has already reported.
  let save: @MainActor () -> Bool
  /// Puts the edit back in front of the person, where there is somewhere to put it.
  var cancel: (@MainActor () -> Void)?
}

@MainActor
extension WorkspaceViewModel {
  /// Asks first when saving `draft` would move a repeating task onto its
  /// next turn. Returns whether it asked: if so the caller saves nothing, and
  /// `save` runs once the person has chosen to.
  func askAboutRecurrenceClash(
    _ draft: TaskEditorDraft, title: String,
    save: @escaping @MainActor () -> Bool,
    cancel: (@MainActor () -> Void)? = nil
  ) -> Bool {
    // A draft that does not validate is the save's to refuse, with its message.
    guard let store, let clash = try? store.recurrenceClash(for: draft) else { return false }
    presentOverlay(.recurrenceClash(WorkspaceRecurrenceClashRequest(
      taskTitle: title, clash: clash, draft: draft, save: save, cancel: cancel)))
    return true
  }

  func resolveRecurrenceClash(_ request: WorkspaceRecurrenceClashRequest, choice: RecurrenceClashChoice) {
    dismissOverlay()
    guard choice.saves else {
      request.cancel?()
      return
    }
    guard request.save(), choice.addsCopy, let store else { return }
    perform {
      try store.addOccurrenceCopy(request.draft)
      reloadOutline()
      reloadDailies()
      reloadNextUp()
    }
  }
}

/// The three ways out of a clash, as rows: ↩ or 1 stacks, 2 keeps both, and
/// escape — the host's — cancels.
struct WorkspaceRecurrenceClashOverlay: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let overlayID: String
  let request: WorkspaceRecurrenceClashRequest
  @State private var selection = 0

  private let choices = RecurrenceClashChoice.allCases

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: theme.space.xxs) {
        Text(request.clash.title(task: request.taskTitle) { TaskRecurrenceClash.dayText($0) })
          .font(theme.bodyFont().weight(.semibold))
          .foregroundStyle(theme.ink)
        Text(request.clash.message { TaskRecurrenceClash.dayText($0) })
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
      }
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, theme.listGutter)
      .padding(.vertical, theme.space.sm)
      FocusRule()
      ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
        Button {
          model.resolveRecurrenceClash(request, choice: choice)
        } label: {
          HStack(spacing: theme.space.sm) {
            Text(choice.title).foregroundStyle(choice == .cancel ? theme.muted : theme.ink)
            if let detail = choice.detail {
              Text(detail).font(theme.captionFont).foregroundStyle(theme.dim)
            }
            Spacer()
            Text(Self.key(for: choice)).font(theme.monoCaptionFont).foregroundStyle(theme.dim)
          }
          .overlayRow(isSelected: index == selection)
        }
        .buttonStyle(.plain)
      }
      WorkspaceOverlayFooter(hints: "↑↓ choose · ↩ or 1 stack · 2 keep both · esc cancel")
    }
    .overlayKeys(model, id: overlayID) { key in
      if let offset = WorkspaceOverlayStep.offset(for: key) {
        selection = WorkspaceOverlayStep.index(from: selection, by: offset, count: choices.count) ?? 0
        return true
      }
      switch key {
      case "enter": model.resolveRecurrenceClash(request, choice: choices[selection])
      case "1": model.resolveRecurrenceClash(request, choice: .stack)
      case "2": model.resolveRecurrenceClash(request, choice: .keepBoth)
      default: break
      }
      // Nothing behind it takes a key while it is up.
      return true
    }
  }

  private static func key(for choice: RecurrenceClashChoice) -> String {
    switch choice {
    case .stack: "1 ↩"
    case .keepBoth: "2"
    case .cancel: "esc"
    }
  }
}
