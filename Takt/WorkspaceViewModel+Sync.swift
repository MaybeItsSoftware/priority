import Foundation
import TaktSync

/// The Mac's end of multi-device sync (`docs/sync.md`). The session watches
/// the outbox for local writes and pulls in the background; all this side has
/// to do is start it and reload when a pull changes something.
extension WorkspaceViewModel {
  func startSync() {
    guard syncSession == nil, let store else { return }
    let session = SyncSession(
      store: store, deviceName: Host.current().localizedName ?? "Mac", platform: "macos")
    session.onRemoteChanges = { [weak self] in self?.reloadAfterExternalWrite() }
    syncSession = session
    session.activate()
  }
}
