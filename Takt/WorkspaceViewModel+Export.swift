import Foundation
import TaktWorkspace

/// The whole workspace written out to a file, for a backup or another app.
///
/// It replaced an export of the Checkvist task cache, which in a local-first
/// workspace was the wrong data: it saved whichever Checkvist list was last
/// loaded, or nothing, rather than the lists you actually work in.
extension WorkspaceViewModel {
  enum ExportFormat: String, CaseIterable, Identifiable {
    case markdown
    case json

    var id: String { rawValue }
    var title: String { self == .markdown ? "Markdown" : "JSON" }
    var fileExtension: String { self == .markdown ? "md" : "json" }
  }

  /// One list and its whole task tree, depth first.
  struct ExportedList: Encodable {
    let list: TaskList
    let tasks: [WorkspaceTask]
  }

  /// Every list, archived included, with its whole task tree.
  struct ExportSnapshot: Encodable {
    let exportedAt: Date
    let workspace: String
    let lists: [ExportedList]
  }

  enum ExportError: LocalizedError {
    case workspaceUnavailable

    var errorDescription: String? { "The workspace is not open, so there is nothing to export." }
  }

  func exportSnapshot() throws -> ExportSnapshot {
    guard let store, let workspace else { throw ExportError.workspaceUnavailable }
    let lists = try store.lists(in: workspace.id, includingArchived: true)
    return ExportSnapshot(
      exportedAt: .now,
      workspace: workspace.name,
      lists: try lists.map { list in
        ExportedList(list: list, tasks: try Self.taskTree(in: list.id, store: store))
      })
  }

  func exportDocument(_ format: ExportFormat) throws -> String {
    let snapshot = try exportSnapshot()
    switch format {
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      return String(bytes: try encoder.encode(snapshot), encoding: .utf8) ?? ""
    case .markdown:
      return Self.markdown(snapshot)
    }
  }

  /// Depth first, in the outline's own order, so the JSON reads top to bottom
  /// the way the list does.
  private static func taskTree(in listId: String, store: WorkspaceStore) throws -> [WorkspaceTask] {
    func walk(_ parent: String?) throws -> [WorkspaceTask] {
      try store.tasks(in: listId, parentTaskId: parent).flatMap { task in
        [task] + (try walk(task.id))
      }
    }
    return try walk(nil)
  }

  private static func markdown(_ snapshot: ExportSnapshot) -> String {
    var lines = ["# \(snapshot.workspace)", ""]
    for entry in snapshot.lists {
      let suffix = entry.list.isArchived ? " (archived)" : ""
      lines.append("## \(entry.list.name)\(suffix)")
      lines.append("")
      var depth: [String: Int] = [:]
      for task in entry.tasks {
        let level = task.parentTaskId.flatMap { depth[$0].map { $0 + 1 } } ?? 0
        depth[task.id] = level
        let box = task.status == .open ? "[ ]" : "[x]"
        let indent = String(repeating: "  ", count: level)
        lines.append("\(indent)- \(box) \(task.title)")
        for note in task.notes.split(separator: "\n", omittingEmptySubsequences: true) {
          lines.append("\(indent)  > \(note)")
        }
      }
      lines.append("")
    }
    return lines.joined(separator: "\n")
  }
}
