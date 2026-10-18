import Foundation
import TaktCore
import TaktRustCore

/// Task dependencies: a task that waits on others until they are done. The
/// rule — what counts as blocked, where a blocked task sorts, that it is not a
/// next-up candidate — is the Rust core's (core/src/dependencies.rs); this
/// file only turns its rows into models.
extension WorkspaceStore {

  // MARK: - Reading

  /// The tasks `taskId` waits on, open or done.
  public func blockers(of taskId: String) throws -> [WorkspaceTask] {
    try Self.mappingCoreErrors { try core.taskBlockers(taskId: taskId) }.map(WorkspaceTask.init)
  }

  /// The tasks waiting on `taskId`.
  public func tasksBlocked(by taskId: String) throws -> [WorkspaceTask] {
    try Self.mappingCoreErrors { try core.tasksBlockedBy(taskId: taskId) }.map(WorkspaceTask.init)
  }

  /// Every open task still waiting on an open task: the ones a client draws
  /// dimmed.
  public func blockedTaskIds() throws -> Set<String> {
    Set(try Self.mappingCoreErrors { try core.blockedTaskIds() })
  }

  /// The open tasks whose start is still to come at `now` (the core's
  /// `buried::buried_task_ids`), each with its start: what a client draws
  /// greyed, with the day it starts, in the buried section.
  public func buriedStarts(now: Date = Date()) throws -> [String: Date] {
    let ids = try Self.mappingCoreErrors { try core.buriedTaskIds(nowMs: now.coreMilliseconds) }
    var starts: [String: Date] = [:]
    for id in ids {
      if let start = try Self.mappingCoreErrors({ try core.metadata(taskId: id) })?.startAtMs {
        starts[id] = Date(coreMilliseconds: start)
      }
    }
    return starts
  }

  /// Whether `taskId` is open and waits on an open task.
  public func isTaskBlocked(_ taskId: String) throws -> Bool {
    try Self.mappingCoreErrors { try core.isTaskBlocked(taskId: taskId) }
  }

  // MARK: - Writing

  /// Makes `taskId` wait on `blockedByTaskId`, as one "Add Blocker" undo
  /// step. Returns whether the dependency is new. Throws
  /// `WorkspaceStoreError.dependencyCycle` for a task waiting on itself, or
  /// on a task that already waits on it.
  @discardableResult
  public func addBlocker(_ blockedByTaskId: String, to taskId: String, now: Date = .now) throws -> Bool {
    try coreWrite {
      try core.addTaskBlocker(taskId: taskId, blockedByTaskId: blockedByTaskId, nowMs: now.coreMilliseconds)
    }
  }

  /// A blocker that does not exist yet: writes what was typed as a new task
  /// at `task`'s level — its list, its parent and its board column — just
  /// above it, and makes `task` wait on it, as one "New Blocker" undo step.
  /// The title is read as the add field reads it (`TaskCapture`), so `!1`,
  /// `@fri` and `45m` work here too. Returns the new task.
  public func createBlocker(capturing typed: String, for task: WorkspaceTask, now: Date = .now) throws -> WorkspaceTask {
    let capture = TaskCapture.parse(typed, now: now)
    // Waiting on someone is the blocked task's column, not something a new
    // task inherits: it would sit there with nobody named.
    let column = try kanbanColumn(for: task.id).flatMap { $0 == "waiting-on" ? nil : $0 }
    let new = NewTask(
      listId: task.listId, title: capture.title, parentTaskId: task.parentTaskId, kind: WorkspaceItemKind.task.rawValue,
      notes: "", kanbanColumn: column, startAtMs: nil, dueAtMs: capture.dueAt?.coreMilliseconds,
      estimateSeconds: capture.estimateSeconds.map(Int64.init), tags: capture.tags,
      priority: capture.priority.map(Int64.init), waitingOn: capture.waitingOn, externalLinks: [], atTop: false,
      adjacentTaskId: task.id, above: true)
    let id = try coreWrite {
      try core.createTaskBlocker(taskId: task.id, task: new, nowMs: now.coreMilliseconds)
    }
    guard let created = try self.task(id: id) else { throw WorkspaceStoreError.missingTask }
    return created
  }

  /// Stops `taskId` waiting on `blockedByTaskId`, as one "Remove Blocker"
  /// undo step. Returns whether there was such a dependency.
  @discardableResult
  public func removeBlocker(_ blockedByTaskId: String, from taskId: String) throws -> Bool {
    try coreWrite { try core.removeTaskBlocker(taskId: taskId, blockedByTaskId: blockedByTaskId) }
  }
}
