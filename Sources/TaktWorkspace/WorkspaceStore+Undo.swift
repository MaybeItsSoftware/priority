import Foundation

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
