import Foundation
import GRDB

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
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    return try database.read { db in
      // Nil for a query that is all punctuation — FTS5 has nothing to match on,
      // which is an empty result rather than an error.
      guard let pattern = try? FTS5Pattern(matchingAllPrefixesIn: trimmed) else { return [] }

      var conditions = ["tasks_fts MATCH ?", "task_lists.workspaceId = ?"]
      var arguments: [any DatabaseValueConvertible] = [pattern, workspaceId]
      if !includingCompleted {
        conditions.append("tasks.status = ?")
        arguments.append(TaskStatus.open.rawValue)
      }
      if !includingArchivedLists {
        conditions.append("task_lists.isArchived = 0")
      }
      arguments.append(limit)

      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT tasks.*, task_lists.id AS matchedListId,
            snippet(tasks_fts, 1, '', '', '…', 10) AS notesSnippet
          FROM tasks_fts
          JOIN tasks ON tasks.rowid = tasks_fts.rowid
          JOIN task_lists ON task_lists.id = tasks.listId
          WHERE \(conditions.joined(separator: " AND "))
          ORDER BY bm25(tasks_fts, 10.0, 1.0)
          LIMIT ?
          """,
        arguments: StatementArguments(arguments))

      var listsByID: [String: TaskList] = [:]
      return try rows.compactMap { row in
        let task = try WorkspaceTask(row: row)
        let listID: String = row["matchedListId"]
        if listsByID[listID] == nil { listsByID[listID] = try TaskList.fetchOne(db, key: listID) }
        guard let list = listsByID[listID] else { return nil }
        let snippet: String? = row["notesSnippet"]
        return TaskSearchResult(
          task: task, list: list,
          notesSnippet: snippet?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty)
      }
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

private extension String {
  var nilWhenEmpty: String? { isEmpty ? nil : self }
}
