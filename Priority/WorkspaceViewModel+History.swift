import AppKit
import Foundation
import PriorityWorkspace

/// Taking back the last change. Split from `WorkspaceViewModel.swift` — the
/// same type — because undo is about the workspace's history rather than its
/// present state.
@MainActor
extension WorkspaceViewModel {
  var undoLabel: String? { (try? store?.undoableLabel()) ?? nil }
  var redoLabel: String? { (try? store?.redoableLabel()) ?? nil }

  func undoLastChange() {
    apply { try $0.undo() }
  }

  func redoLastUndoneChange() {
    apply { try $0.redo() }
  }

  private func apply(_ step: (WorkspaceStore) throws -> String?) {
    guard let store else { return }
    perform {
      guard try step(store) != nil else {
        // Nothing left in that direction. The beep is the whole feedback, the
        // same as anywhere else in macOS.
        NSSound.beep()
        return
      }
      try load()
      // Undo can remove whatever was selected, and a selection pointing at a
      // task that no longer exists leaves the inspector showing a ghost.
      if let selectedTaskID, (try? store.task(id: selectedTaskID)) ?? nil == nil {
        self.selectedTaskID = nil
        isInspectorVisible = false
      }
      if let scopeTaskID, (try? store.task(id: scopeTaskID)) ?? nil == nil {
        self.scopeTaskID = nil
        reloadOutline()
      }
    }
  }
}
