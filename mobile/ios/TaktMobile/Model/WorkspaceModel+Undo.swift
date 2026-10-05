import Foundation

@MainActor
extension WorkspaceModel {
  /// Shake to undo.
  func confirmShakeUndo() {
    guard undoLabel != nil else { return }
    undo()
  }
}
