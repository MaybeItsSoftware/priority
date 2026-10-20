import Foundation
import SwiftUI
import TaktWorkspace

/// A save that moves a repeating task onto or past the day it comes round
/// again anyway, held until the person says what should happen. The Rust
/// core decides it is a clash (`WorkspaceStore.recurrenceClash(for:)`); the
/// wording and the three choices are `TaskRecurrenceClash`'s and
/// `RecurrenceClashChoice`'s, the same on the Mac.
struct PendingRecurrenceClash: Identifiable {
  /// Where the dialog is drawn: over the inspector when it asked from there,
  /// over the app otherwise. A sheet hides anything presented behind it.
  enum Surface { case app, inspector }

  let id = UUID()
  let taskTitle: String
  let clash: TaskRecurrenceClash
  var surface: Surface = .app
  let resolve: @MainActor (RecurrenceClashChoice) -> Void

  var title: String { clash.title(task: taskTitle) { TaskRecurrenceClash.dayText($0) } }
  var message: String { clash.message { TaskRecurrenceClash.dayText($0) } }
}

extension WorkspaceModel {
  /// Asks first when saving `draft` would move a repeating task onto its
  /// next turn. Returns whether it asked: if so the caller saves nothing,
  /// and `save` runs once the person has chosen to. "Keep both" then copies
  /// the task as `save` left it. `saved` follows a save made from the
  /// dialog, for the caller's own feedback.
  func askAboutRecurrenceClash(
    _ draft: TaskEditorDraft,
    surface: PendingRecurrenceClash.Surface = .app,
    save: @escaping @MainActor () -> Bool,
    saved: (@MainActor () -> Void)? = nil
  ) -> Bool {
    // A draft that does not validate is the save's to refuse, with its message.
    guard let clash = try? store.recurrenceClash(for: draft) else { return false }
    let taskID = draft.baseline.taskId
    recurrenceClash = PendingRecurrenceClash(
      taskTitle: draft.values.title, clash: clash, surface: surface
    ) { [weak self] choice in
      guard let self else { return }
      recurrenceClash = nil
      // Cancel saves nothing: the edit stays where it was made, to change.
      guard choice.saves, save() else { return }
      saved?()
      guard choice.addsCopy else { return }
      // The copy joins the move's step as "Keep Both", which the toast offers to undo.
      let copied = perform { store in
        try store.addOccurrenceCopy(TaskEditorDraft(snapshot: try store.taskEditorSnapshot(for: taskID)))
      }
      if copied { announce() }
    }
    return true
  }

  /// The same, for a write that only moves the start (`scheduleTask`): asks
  /// about the task as it would be with that start.
  func askAboutRecurrenceClash(
    starting taskID: String, at start: Date?,
    save: @escaping @MainActor () -> Bool,
    saved: (@MainActor () -> Void)? = nil
  ) -> Bool {
    guard var draft = try? TaskEditorDraft(snapshot: store.taskEditorSnapshot(for: taskID)) else { return false }
    draft.values.startAt = start
    return askAboutRecurrenceClash(draft, save: save, saved: saved)
  }
}

extension View {
  /// The bottom-sheet dialog for a pending clash drawn on `surface`.
  func recurrenceClashDialog(
    _ model: WorkspaceModel, on surface: PendingRecurrenceClash.Surface = .app
  ) -> some View {
    modifier(RecurrenceClashDialog(model: model, surface: surface))
  }
}

private struct RecurrenceClashDialog: ViewModifier {
  let model: WorkspaceModel
  let surface: PendingRecurrenceClash.Surface

  func body(content: Content) -> some View {
    content.confirmationDialog(
      model.recurrenceClash?.title ?? "", isPresented: isPresented, titleVisibility: .visible,
      presenting: model.recurrenceClash
    ) { pending in
      Button(RecurrenceClashChoice.stack.title) { pending.resolve(.stack) }
        .accessibilityIdentifier("recurrenceClash.stack")
      Button(RecurrenceClashChoice.keepBoth.title) { pending.resolve(.keepBoth) }
        .accessibilityIdentifier("recurrenceClash.keepBoth")
      Button(RecurrenceClashChoice.cancel.title, role: .cancel) { pending.resolve(.cancel) }
    } message: { pending in
      Text(pending.message)
    }
  }

  /// Dismissing the dialog any other way — a tap outside it — is Cancel.
  /// A turn later, so a button's own choice is made first.
  private var isPresented: Binding<Bool> {
    Binding(
      get: { model.recurrenceClash?.surface == surface },
      set: { shown in
        guard !shown, let pending = model.recurrenceClash, pending.surface == surface else { return }
        DispatchQueue.main.async {
          if model.recurrenceClash?.id == pending.id { pending.resolve(.cancel) }
        }
      })
  }
}
