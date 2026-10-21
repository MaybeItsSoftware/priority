import AppKit
import Foundation
import TaktWorkspace

/// Taking back the last change. Split from `WorkspaceViewModel.swift` — the
/// same type — because undo is about the workspace's history rather than its
/// present state.
@MainActor
extension WorkspaceViewModel {
  // `undoLabel` and `redoLabel` are stored on the class and refreshed after
  // each write by `refreshHistoryLabels()`.

  func undoLastChange() {
    apply(forUndo: true) { try $0.undo() }
  }

  func redoLastUndoneChange() {
    apply(forUndo: false) { try $0.redo() }
  }

  private func apply(forUndo: Bool, _ step: (WorkspaceStore) throws -> String?) {
    guard let store else { return }
    taskEditor.flush()
    taskInsertionReference = nil
    var restored: WorkspaceTask?
    perform {
      let target = try store.historyTarget(forUndo: forUndo)
      guard try step(store) != nil else {
        // Nothing left in that direction. The beep is the whole feedback, the
        // same as anywhere else in macOS.
        NSSound.beep()
        return
      }
      try load()
      taskEditor.refresh(store: store)
      // Undo can remove whatever was selected, and a selection pointing at a
      // task that no longer exists leaves the inspector showing a ghost.
      if let selectedTaskID, (try? store.task(id: selectedTaskID)) ?? nil == nil {
        self.selectedTaskID = nil
      }
      if let scopeTaskID, (try? store.task(id: scopeTaskID)) ?? nil == nil {
        self.scopeTaskID = nil
        reloadOutline()
      }
      if let listID = target.listId, lists.contains(where: { $0.id == listID }) {
        selectList(listID)
      }
      if selectedTaskID == nil, let taskID = target.taskId {
        restored = try store.task(id: taskID)
      }
      if let selectedFolderID, !folders.contains(where: { $0.id == selectedFolderID }) {
        self.selectedFolderID = nil
      }
    }
    // With nothing selected, the task the step brought back is selected —
    // where it already shows if it does, Today, a folder or a filter list
    // included, in the mode you are in. Only a task that cannot be seen from
    // here moves you, and then as search's reveal does, never into the
    // outline: the inspector shows it either way. Nor does it turn off
    // "hide completed" or unfold anything, which would outlast the undo.
    if let restored {
      showInPlace(
        task(withID: restored.id) ?? restored, fallsBackToOutline: false, takesKeyboard: false,
        revealsHidden: false)
    }
  }

  /// Menu commands follow the same text/workspace ownership as the key monitor.
  func applyHistoryFromMenu(redo: Bool) {
    if let text = NSApp.keyWindow?.firstResponder as? NSTextView {
      if let manager = text.undoManager {
        if redo && manager.canRedo {
          manager.redo()
        } else if !redo && manager.canUndo {
          manager.undo()
        }
      }
    } else {
      if redo { redoLastUndoneChange() } else { undoLastChange() }
    }
  }
}
