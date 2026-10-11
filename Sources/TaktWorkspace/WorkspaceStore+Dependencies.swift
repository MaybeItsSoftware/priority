import Foundation

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

  /// Stops `taskId` waiting on `blockedByTaskId`, as one "Remove Blocker"
  /// undo step. Returns whether there was such a dependency.
  @discardableResult
  public func removeBlocker(_ blockedByTaskId: String, from taskId: String) throws -> Bool {
    try coreWrite { try core.removeTaskBlocker(taskId: taskId, blockedByTaskId: blockedByTaskId) }
  }
}
