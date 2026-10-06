import Foundation
import TaktWorkspace
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
/// connection's commit. It is one integer read a second, awaited on the
/// writer's queue so the main thread never waits behind a write, and since the
/// writer never counts its own commits, the app's writes cannot be mistaken
/// for someone else's. When it moves, the view model reloads the way undo does, since an
/// external write is the same kind of event: rows changed underneath the
/// screen, possibly including whatever is selected.
///
/// Undo needs no help. The CLI records its writes in the same `change_log`
/// under labels such as "MCP: New Task", so they are already steps in the
/// Undo menu once they have been reloaded.
extension WorkspaceViewModel {
  private static let externalWriteLog = Logger(
    subsystem: "uk.co.maybeitssoftware.takt", category: "WorkspaceExternalWrites")

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

  /// Awaits the token rather than reading it in line, so a poll that lands
  /// behind a write waits on the writer's queue instead of holding the main
  /// thread. One check at a time: a tick that finds the last still waiting
  /// skips, and a burst of writes is one reload per tick at most.
  func checkForExternalWrites() {
    guard let store, !externalWriteCheckInFlight else { return }
    checkForDayChange()
    checkForDueFollowUps()
    externalWriteCheckInFlight = true
    Task { @MainActor [weak self] in
      let token = try? await store.readExternalChangeToken()
      guard let self else { return }
      self.externalWriteCheckInFlight = false
      guard let token, token != self.externalWriteToken else { return }
      self.externalWriteToken = token
      self.reloadAfterExternalWrite()
    }
  }

  /// Also run after a sync pull lands rows from another device.
  func reloadAfterExternalWrite() {
    guard let store else { return }
    Self.externalWriteLog.debug("Another process wrote to the workspace; reloading")
    // Before the reload, so a draft being typed is saved to disk and then
    // reconciled against the new rows rather than lost or silently overwritten.
    // A field changed on both sides becomes a conflict the editor shows.
    taskEditor.flush()
    // Themes and the choice of one are rows too, and arrive the same way.
    onWorkspaceChangedElsewhere?()
    perform {
      try load()
      // Same clean-up as after undo: whatever was selected may be gone.
      if let selectedTaskID, (try? store.task(id: selectedTaskID)) ?? nil == nil {
        self.selectedTaskID = nil
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
