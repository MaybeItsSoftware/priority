import Foundation
import GRDB

/// One labelled step in the undo journal.
struct UndoStep: Identifiable, Equatable, Sendable {
  let id: String
  let label: String
  /// Undone steps are the redo stack.
  let isUndone: Bool
  /// How many rows the step touched — "Delete Task" on a branch of twelve
  /// reads differently from one on a leaf.
  let changeCount: Int
}

/// The undo and redo stacks, newest undo first.
struct UndoHistory: Equatable, Sendable {
  var undo: [UndoStep] = []
  var redo: [UndoStep] = []

  static let empty = UndoHistory()

  /// How many undos take the workspace back to just before `step`.
  func undoCount(through step: UndoStep) -> Int? {
    undo.firstIndex(of: step).map { $0 + 1 }
  }

  /// How many redos bring `step` back.
  func redoCount(through step: UndoStep) -> Int? {
    redo.firstIndex(of: step).map { $0 + 1 }
  }
}

/// Reads the store's undo journal for the history sheet.
///
/// `WorkspaceStore` publishes the next label each way (`undoableLabel`,
/// `redoableLabel`) but not the whole journal, so this opens its own
/// read-only connection to the same file and reads `change_log` — the table
/// `journalledWrite` fills — grouped the way `undo()` replays it. Read only:
/// every undo and redo still goes through the store.
enum UndoHistoryReader {
  static func read(databaseURL: URL) throws -> UndoHistory {
    var configuration = Configuration()
    configuration.readonly = true
    let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
    return try queue.read { db in
      let rows = try Row.fetchAll(db, sql: """
        SELECT groupId, MAX(label) AS label, MAX(undone) AS undone, COUNT(*) AS changes, MAX(id) AS lastId,
          MIN(id) AS firstId
        FROM change_log
        WHERE groupId IS NOT NULL
        GROUP BY groupId
        """)
      let steps = rows.map { row -> (UndoStep, Int64, Int64) in
        let step = UndoStep(
          id: row["groupId"], label: (row["label"] as String?) ?? "Change",
          isUndone: (row["undone"] as Bool?) ?? false, changeCount: row["changes"])
        return (step, row["lastId"], row["firstId"])
      }
      // Undo takes the newest done group first; redo the oldest undone.
      let undo = steps.filter { !$0.0.isUndone }.sorted { $0.1 > $1.1 }.map(\.0)
      let redo = steps.filter { $0.0.isUndone }.sorted { $0.2 < $1.2 }.map(\.0)
      return UndoHistory(undo: undo, redo: redo)
    }
  }
}
