import Foundation
import PriorityCore

extension WorkspaceStore {
  /// `createTask`, for a title a person typed: the details written on the end
  /// of it (`45m #work @fri !1` — see `TaskCapture`) are read off and filed
  /// with the task in the same undo step.
  ///
  /// Only for text typed into an add field. A title that arrives from an
  /// import, a sync or an assistant is stored as given, because nobody saw a
  /// preview of what would be read off it.
  public func createTask(
    capturing typed: String,
    listId: String,
    parentTaskId: String? = nil,
    kanbanColumn: String? = nil,
    startAt: Date? = nil,
    atTop: Bool = false,
    adjacentTaskId: String? = nil,
    above: Bool = false,
    now: Date = .now
  ) throws -> WorkspaceTask {
    let capture = TaskCapture.parse(typed, now: now)
    return try createTask(
      listId: listId, title: capture.title, parentTaskId: parentTaskId, kanbanColumn: kanbanColumn,
      startAt: startAt, atTop: atTop, adjacentTaskId: adjacentTaskId, above: above,
      dueAt: capture.dueAt, estimateSeconds: capture.estimateSeconds, tags: capture.tags,
      priority: capture.priority, now: now)
  }
}
