import Foundation

enum UndoableAction {
  case add(taskId: Int)
  case markDone(taskId: Int)
  case invalidate(taskId: Int)
  case update(taskId: Int, oldContent: String, oldDue: String?)
}
