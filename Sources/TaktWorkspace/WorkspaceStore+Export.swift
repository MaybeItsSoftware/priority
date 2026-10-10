import Foundation
import TaktRustCore

/// The two formats the workspace is written out in.
public enum WorkspaceExportFormat: String, CaseIterable, Identifiable, Sendable {
  case markdown
  case json

  public var id: String { rawValue }
  public var title: String { self == .markdown ? "Markdown" : "JSON" }
  public var fileExtension: String { self == .markdown ? "md" : "json" }

  var core: ExportFormat { self == .markdown ? .markdown : .json }
}

extension WorkspaceStore {
  /// The whole workspace written out to a file, for a backup or another app:
  /// every list, archived included, with its whole task tree depth first. The
  /// Rust core's `export::export` reads and writes it in one call, so no row
  /// crosses. Nil when there is no such workspace.
  public func exportDocument(
    workspaceId: String, format: WorkspaceExportFormat, exportedAt: Date = .now
  ) throws -> String? {
    try Self.mappingCoreErrors {
      try core.exportWorkspace(
        workspaceId: workspaceId, format: format.core, exportedAtMs: exportedAt.coreMilliseconds)
    }
  }
}
