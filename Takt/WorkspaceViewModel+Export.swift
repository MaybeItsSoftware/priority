import Foundation
import TaktWorkspace

/// The whole workspace written out to a file, for a backup or another app.
///
/// It replaced an export of the Checkvist task cache, which in a local-first
/// workspace was the wrong data: it saved whichever Checkvist list was last
/// loaded, or nothing, rather than the lists you actually work in. The
/// document is the Rust core's (`core/src/export.rs`): it reads every list and
/// its tree and writes them in one call, so no row crosses.
extension WorkspaceViewModel {
  enum ExportError: LocalizedError {
    case workspaceUnavailable

    var errorDescription: String? { "The workspace is not open, so there is nothing to export." }
  }

  func exportDocument(_ format: WorkspaceExportFormat) throws -> String {
    guard let store, let workspace,
      let document = try store.exportDocument(workspaceId: workspace.id, format: format)
    else { throw ExportError.workspaceUnavailable }
    return document
  }
}
