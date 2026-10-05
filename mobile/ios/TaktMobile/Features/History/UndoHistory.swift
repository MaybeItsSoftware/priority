import Foundation
import TaktWorkspace

typealias UndoStep = WorkspaceUndoStep

/// The undo and redo stacks, each with its next step first.
struct UndoHistory: Equatable, Sendable {
  var undo: [UndoStep] = []
  var redo: [UndoStep] = []

  static let empty = UndoHistory()

  /// Splits the store's history — newest first, undone steps on top — into
  /// the two stacks: undo newest first, redo oldest (the next redo) first.
  init(steps: [UndoStep]) {
    undo = steps.filter { !$0.isUndone }
    redo = steps.filter(\.isUndone).reversed()
  }

  init(undo: [UndoStep] = [], redo: [UndoStep] = []) {
    self.undo = undo
    self.redo = redo
  }

  /// Reads the journal through the store. Off the main actor: the caller is
  /// a `StoreQuery`.
  static func read(_ store: WorkspaceStore) throws -> UndoHistory {
    UndoHistory(steps: try store.undoHistory(limit: 100))
  }

  /// How many undos take the workspace back to just before `step`.
  func undoCount(through step: UndoStep) -> Int? {
    undo.firstIndex(of: step).map { $0 + 1 }
  }

  /// How many redos bring `step` back.
  func redoCount(through step: UndoStep) -> Int? {
    redo.firstIndex(of: step).map { $0 + 1 }
  }
}
