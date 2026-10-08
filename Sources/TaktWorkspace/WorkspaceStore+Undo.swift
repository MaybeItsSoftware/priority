import Foundation
import GRDB

/// Taking back the last thing you did. Split from `WorkspaceStore.swift` — the
/// same type — because it is a mechanism rather than a feature: nothing else in
/// the store knows it exists.
///
/// Rather than every mutation declaring its own inverse — which is one more
/// thing to get wrong each time a mutation is added — the database records what
/// changed. Triggers on the tables that hold the user's work write the row
/// before and after each insert, update and delete into `change_log`, and undo
/// replays those entries backwards. A mutation added later is covered the day
/// it is written, provided its write goes through `journalledWrite`.
///
/// Focus sessions and the focus queue are deliberately not journalled. A timer
/// is a record of what happened, not an edit to take back, and undoing your way
/// into a half-finished session would be a strange thing to offer.
extension WorkspaceStore {
  /// What undo would take back, phrased for a menu item. Nil when there is
  /// nothing to undo.
  public func undoableLabel() throws -> String? {
    try core.undoableLabel()
  }

  public func redoableLabel() throws -> String? {
    try core.redoableLabel()
  }

  /// The journal's named steps, newest first, at most `limit` of them.
  ///
  /// The undone steps (the redo stack) come first, since they were done
  /// later than anything still standing; the last of them is the next redo,
  /// and the first step that is not undone is the next undo.
  public func undoHistory(limit: Int = 100) throws -> [WorkspaceUndoStep] {
    try core.undoHistory(limit: UInt32(clamping: max(0, limit))).map { step in
      WorkspaceUndoStep(
        id: step.id, label: step.label, isUndone: step.isUndone, changeCount: Int(step.changeCount))
    }
  }

  /// The affected task/list lets the desktop reveal restored work after undo.
  public func historyTarget(forUndo: Bool) throws -> (taskId: String?, listId: String?) {
    let target = try core.historyTarget(forUndo: forUndo)
    return (target.taskId, target.listId)
  }

  /// Reverses the most recent group of changes. Returns its label, or nil when
  /// there was nothing to undo.
  ///
  /// The replay is the core's (core/src/journal.rs), on its own connection: a
  /// commit GRDB's observation does not see, so callers reload afterwards, as
  /// the view model's `perform` already does. `coreWrite` keeps it from
  /// looking like another process's commit.
  @discardableResult
  public func undo() throws -> String? {
    try coreWrite { try core.undo() }
  }

  @discardableResult
  public func redo() throws -> String? {
    try coreWrite { try core.redo() }
  }

  /// Runs a mutation as one undoable step.
  ///
  /// The label is what the user will be offered back, so it names the action
  /// rather than the table. Every write that touches a journalled table goes
  /// through here: a write that does not would be recorded against whichever
  /// step ran before it, and undoing that step would take back both.
  ///
  /// The bookkeeping matches `journal::begin` and `journal::finish` in the
  /// core statement for statement. It stays here until the writes it wraps
  /// move into the core (step four), because it has to run inside GRDB's
  /// transaction, which the core's connection cannot join.
  func journalledWrite<T>(_ label: String, _ block: (Database) throws -> T) throws -> T {
    try database.write { db in
      let groupID = UUID().uuidString
      // Recording is off by default, so a write that has not opted in — a
      // migration, an import, the focus tables — is not an undo step. It is
      // switched on here and off again below, inside the one transaction.
      try db.execute(
        sql: "UPDATE undo_control SET groupId = ?, label = ?, suppressed = 0 WHERE id = 0",
        arguments: [groupID, label])
      defer { try? db.execute(sql: "UPDATE undo_control SET suppressed = 1 WHERE id = 0") }
      let result = try block(db)
      try db.execute(sql: "UPDATE undo_control SET suppressed = 1 WHERE id = 0")
      // A key pressed at the end of a list can be a no-op. Only an actual
      // change creates a new history branch and invalidates redo.
      let changed = try Bool.fetchOne(
        db, sql: "SELECT EXISTS(SELECT 1 FROM change_log WHERE groupId = ?)", arguments: [groupID]) ?? false
      if changed { try db.execute(sql: "DELETE FROM change_log WHERE undone = 1") }
      // Whole groups only: half an undo step is worse than none. The depth is
      // the core's JOURNAL_DEPTH.
      try db.execute(sql: """
        DELETE FROM change_log WHERE groupId IN (
          SELECT groupId FROM change_log GROUP BY groupId
          ORDER BY MAX(id) DESC LIMIT -1 OFFSET 100
        )
        """)
      return result
    }
  }
}

/// One named step in the undo journal, as `undoHistory(limit:)` reports it.
public struct WorkspaceUndoStep: Identifiable, Equatable, Hashable, Sendable {
  /// The journal group the step's changes share.
  public let id: String
  /// What the step is offered back as — "New Task", "Delete List".
  public let label: String
  /// Undone steps are the redo stack.
  public let isUndone: Bool
  /// How many rows the step touched.
  public let changeCount: Int

  public init(id: String, label: String, isUndone: Bool, changeCount: Int) {
    self.id = id
    self.label = label
    self.isUndone = isUndone
    self.changeCount = changeCount
  }
}
