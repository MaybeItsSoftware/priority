import Foundation
import TaktRustCore

/// Finding a task by what it says. Split from `WorkspaceStore.swift` — the same
/// type — because searching reads through an index the rest of the store never
/// touches.
extension WorkspaceStore {
  /// Searches task titles and notes across the workspace.
  ///
  /// The query is treated as a set of prefixes, so results narrow as the user
  /// types rather than appearing only once a word is finished. Titles are
  /// weighted far above notes: a task called "Invoice" should beat one that
  /// merely mentions invoices in a paragraph of notes.
  public func searchTasks(
    in workspaceId: String,
    matching query: String,
    includingCompleted: Bool = false,
    includingArchivedLists: Bool = false,
    limit: Int = 60
  ) throws -> [TaskSearchResult] {
    // The Rust core's `search::search`, which Android calls too.
    try Self.mappingCoreErrors {
      try core.searchTasks(
        workspaceId: workspaceId, query: query, includingCompleted: includingCompleted,
        includingArchivedLists: includingArchivedLists, limit: Int64(limit))
    }.map { hit in
      TaskSearchResult(task: WorkspaceTask(hit.task), list: TaskList(hit.list), notesSnippet: hit.notesSnippet)
    }
  }
}

/// One search hit, carrying the list it was found in so the result can say
/// where the task lives without a second query per row.
public struct TaskSearchResult: Identifiable, Sendable, Equatable {
  public let task: WorkspaceTask
  public let list: TaskList
  /// The matching stretch of the notes, when the match was in the notes.
  public let notesSnippet: String?

  public var id: String { task.id }

  public init(task: WorkspaceTask, list: TaskList, notesSnippet: String?) {
    self.task = task
    self.list = list
    self.notesSnippet = notesSnippet
  }
}
