import Foundation
import TaktSync

/// The Mac's end of multi-device sync (`docs/sync.md`). The session watches
/// the outbox for local writes and pulls in the background; all this side has
/// to do is start it and reload when a pull changes something.
extension WorkspaceViewModel {
  /// Called from `init` after `watchForExternalWrites()`, and it has to stay
  /// there: a pull's rows are applied from a background connection, and the
  /// watcher recognises them as someone else's write only once it holds its
  /// first `data_version` token. Started first, a pull that landed before the
  /// token was read would move the token without the reload it is for.
  func startSync() {
    guard syncSession == nil, let store else { return }
    let session = SyncSession(
      store: store, deviceName: Host.current().localizedName ?? "Mac", platform: "macos")
    session.onRemoteChanges = { [weak self] in self?.reloadAfterExternalWrite() }
    syncSession = session
    session.activate()
  }
}
