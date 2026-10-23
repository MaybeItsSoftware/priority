import Foundation
import TaktCore
import TaktRustCore

extension WorkspaceStore {
  /// `createTask`, for a title a person typed: the details written on the end
  /// of it (`45m #work @fri !1` — see `TaskCapture`) are read off and filed
  /// with the task in the same undo step.
  ///
  /// Only for text typed into an add field. A title that arrives from an
  /// import, a sync or an assistant is stored as given, because nobody saw a
  /// preview of what would be read off it.
  ///
  /// `defaultDueAt` is the due date when the text names none — Today's field
  /// passes the day, so what you add there is due on it. A date you typed wins,
  /// and so does a start typed with `^mon` over `startAt`.
  public func createTask(
    capturing typed: String,
    listId: String,
    parentTaskId: String? = nil,
    kanbanColumn: String? = nil,
    startAt: Date? = nil,
    atTop: Bool = false,
    adjacentTaskId: String? = nil,
    above: Bool = false,
    defaultDueAt: Date? = nil,
    now: Date = .now
  ) throws -> WorkspaceTask {
    let capture = TaskCapture.parse(typed, now: now)
    return try createTask(
      listId: listId, title: capture.title, parentTaskId: parentTaskId, kanbanColumn: kanbanColumn,
      startAt: capture.startAt ?? startAt, atTop: atTop, adjacentTaskId: adjacentTaskId, above: above,
      dueAt: capture.dueAt ?? defaultDueAt, estimateSeconds: capture.estimateSeconds, tags: capture.tags,
      priority: capture.priority, waitingOn: capture.waitingOn, externalLinks: capture.links, now: now)
  }

  /// A typed task with what the add field's slots hold: a due day and an
  /// estimate that win over any the title's words name, and the conditions
  /// it needs. All of it one "New Task" step — the Rust core's
  /// `tasks::create_task_requiring` — so one undo takes the lot.
  public func createTask(
    capturing typed: String,
    listId: String,
    parentTaskId: String? = nil,
    dueAt: Date?,
    estimateSeconds: Int?,
    requirementGroups: [[String]],
    now: Date = .now
  ) throws -> WorkspaceTask {
    let capture = TaskCapture.parse(typed, now: now)
    let new = NewTask(
      listId: listId, title: capture.title, parentTaskId: parentTaskId, kind: WorkspaceItemKind.task.rawValue,
      notes: "", kanbanColumn: nil, startAtMs: capture.startAt?.coreMilliseconds,
      dueAtMs: (dueAt ?? capture.dueAt)?.coreMilliseconds,
      estimateSeconds: (estimateSeconds ?? capture.estimateSeconds).map(Int64.init), tags: capture.tags,
      priority: capture.priority.map(Int64.init), waitingOn: capture.waitingOn, externalLinks: capture.links, atTop: false,
      adjacentTaskId: nil, above: false)
    let id = try coreWrite {
      try core.createTaskRequiring(
        task: new, requirementGroups: requirementGroups, nowMs: now.coreMilliseconds,
        zone: TimeZone.current.identifier)
    }
    guard let task = try task(id: id) else { throw WorkspaceStoreError.missingTask }
    return task
  }
}
