import Foundation
import PriorityWorkspace
import os

/// Picking up writes made to the workspace database by another process.
///
/// The `priority` CLI, which is also the app's MCP server, edits folders,
/// lists and tasks in the same SQLite file (`cli/src/workspace_tasks.rs`).
/// Nothing in GRDB reports that here, since its observation only sees this
/// process's own writes, so without this the app would go on showing
/// what it loaded, and an edit made from that stale screen would be made
/// against rows that had already moved.
///
/// The check is `PRAGMA data_version` on the store's writer connection
/// (`WorkspaceStore.externalChangeToken`), which moves only on another
/// connection's commit. It is one integer read a second on the main actor,
/// where every workspace write already runs, so it never races the app's own
/// writes. When it moves, the view model reloads the way undo does, since an
/// external write is the same kind of event: rows changed underneath the
/// screen, possibly including whatever is selected.
///
/// Undo needs no help. The CLI records its writes in the same `change_log`
/// under labels such as "MCP: New Task", so they are already steps in the
/// Undo menu once they have been reloaded.
extension WorkspaceViewModel {
  private static let externalWriteLog = Logger(
    subsystem: "uk.co.maybeitsadam.priority", category: "WorkspaceExternalWrites")

  /// A second is quick enough that a change an assistant reports having made
  /// is already on screen by the time the user looks.
  private static let externalWritePollInterval: TimeInterval = 1

  func watchForExternalWrites() {
    guard externalWriteTimer == nil, let store else { return }
    externalWriteToken = try? store.externalChangeToken()
    let timer = Timer(timeInterval: Self.externalWritePollInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkForExternalWrites() }
    }
    // Most of the interval's slack is fine, and letting the system coalesce it
    // costs nothing that anyone would notice.
    timer.tolerance = 0.5
    RunLoop.main.add(timer, forMode: .common)
    externalWriteTimer = timer
  }

  func checkForExternalWrites() {
    guard let store, let token = try? store.externalChangeToken() else { return }
    guard token != externalWriteToken else { return }
    externalWriteToken = token
    reloadAfterExternalWrite()
  }

  private func reloadAfterExternalWrite() {
    guard let store else { return }
    Self.externalWriteLog.debug("Another process wrote to the workspace; reloading")
    // Before the reload, so a draft being typed is saved to disk and then
    // reconciled against the new rows rather than lost or silently overwritten.
    // A field changed on both sides becomes a conflict the editor shows.
    taskEditor.flush()
    perform {
      try load()
      // Same clean-up as after undo: whatever was selected may be gone.
      if let selectedTaskID, (try? store.task(id: selectedTaskID)) ?? nil == nil {
        self.selectedTaskID = nil
        isInspectorVisible = false
      }
      if let scopeTaskID, (try? store.task(id: scopeTaskID)) ?? nil == nil {
        self.scopeTaskID = nil
        reloadOutline()
      }
      if let selectedFolderID, !folders.contains(where: { $0.id == selectedFolderID }) {
        self.selectedFolderID = nil
      }
    }
  }
}
