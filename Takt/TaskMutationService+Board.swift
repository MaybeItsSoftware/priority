import Foundation

/// The kanban board's two mutations.
///
/// Split out of `TaskMutationService.swift` only to keep both files under the
/// SwiftLint length limits; they are the same service and share its private
/// helpers (`restoreTask`, `removeOptimisticTask`, `queueOfflineCreate`,
/// `resolveMutationFailure`), which is why this is an extension rather than a
/// new type.
extension TaskMutationService {
  // MARK: - Board Mutations
  //
  // These two arrived here from `AppCoordinator`, which was the last place
  // still hand-rolling the optimistic-mutation dance. Both had drifted from
  // the shared version while they were up there: the update path wrote
  // `pendingTaskMutations` directly and so never reached disk, and the add
  // path had no offline branch at all — a card added while offline was simply
  // discarded when the request failed. Routing them through
  // `resolveMutationFailure` and the repository's write-through enqueues is
  // most of the reason to move them.

  /// Applies a content/due edit locally at once and syncs it in the
  /// background, rolling back if the server rejects it.
  ///
  /// Used by the kanban board, where "move to a column" *is* a content/due
  /// edit — the column is encoded in the task itself.
  ///
  /// Returns the background sync so a test can await it. Callers ignore it:
  /// the point of the method is that the local edit lands immediately.
  @discardableResult
  func applyOptimisticUpdate(
    task: CheckvistTask, content: String?, due: String?
  ) -> Task<Void, Never>? {
    guard let host else { return nil }
    host.lastUndoableAction = .update(
      taskId: task.id, oldContent: task.content, oldDue: task.due)

    guard let index = repository.tasks.firstIndex(where: { $0.id == task.id }) else { return nil }
    let originalTask = repository.tasks[index]
    repository.tasks[index] = CheckvistTask(
      id: originalTask.id,
      content: content ?? originalTask.content,
      status: originalTask.status,
      due: due ?? originalTask.due,
      position: originalTask.position,
      parentId: originalTask.parentId,
      level: originalTask.level,
      notes: originalTask.notes,
      updatedAt: originalTask.updatedAt
    )

    let listId = repository.listId
    let credentials = repository.activeCredentials
    let plugin = repository.activeSyncPlugin
    let taskId = task.id

    return Task { [weak self] in
      do {
        let success = try await plugin.updateTask(
          listId: listId, taskId: taskId, content: content, due: due,
          credentials: credentials)
        guard let self, !success else { return }
        self.restoreTask(originalTask)
        self.repository.errorMessage = "Failed to sync task move."
      } catch {
        guard let self else { return }
        self.resolveMutationFailure(
          whenOffline: {
            // Write-through, so the edit survives a quit before reconnect.
            self.repository.enqueuePendingMutation(
              taskId: taskId, content: content, due: due)
          },
          whenOnline: {
            self.restoreTask(originalTask)
            self.repository.errorMessage = "Failed to sync task move."
          }
        )
      }
    }
  }

  /// Adds a root-level task carrying a due date, and keeps the kanban
  /// selection on it across the optimistic → real id handover.
  ///
  /// Returns the background create for the same reason as
  /// `applyOptimisticUpdate` above.
  @discardableResult
  func addRootTask(content: String, due: String?) -> Task<Void, Never>? {
    guard let host else { return nil }
    guard !repository.listId.isEmpty else {
      repository.errorMessage = "Choose a Checkvist list in Preferences to add tasks."
      return nil
    }

    // Shares the id sequence with the sibling/child inserts above, so no two
    // optimistic paths can hand out the same placeholder.
    let optimisticId = OptimisticTaskID.make()
    repository.tasks.append(
      CheckvistTask(
        id: optimisticId, content: content, status: 0, due: due,
        position: nil, parentId: nil, level: nil))
    host.kanbanSelectedTaskId = optimisticId

    let listId = repository.listId
    let credentials = repository.activeCredentials
    let plugin = repository.activeSyncPlugin

    return Task { [weak self] in
      do {
        let newTask = try await plugin.createTask(
          listId: listId, content: content, parentId: nil, position: nil,
          credentials: credentials)
        guard let self else { return }
        guard let newTask else {
          self.removeOptimisticTask(id: optimisticId)
          self.repository.errorMessage = "Failed to add task."
          return
        }
        // Create carries no due date, so it needs a follow-up edit. Queued
        // rather than fire-and-forget: losing it silently drops the column
        // the card was added to.
        if let due, !due.isEmpty {
          do {
            _ = try await plugin.updateTask(
              listId: listId, taskId: newTask.id, content: nil, due: due,
              credentials: credentials)
          } catch {
            self.repository.enqueuePendingMutation(
              taskId: newTask.id, content: nil, due: due)
          }
        }
        self.host?.lastUndoableAction = .add(taskId: newTask.id)
        if let idx = self.repository.tasks.firstIndex(where: { $0.id == optimisticId }) {
          self.repository.tasks[idx] = CheckvistTask(
            id: newTask.id, content: content, status: 0, due: due,
            position: newTask.position, parentId: nil, level: nil)
        }
        self.host?.kanbanSelectedTaskId = newTask.id
      } catch {
        guard let self else { return }
        self.resolveMutationFailure(
          whenOffline: {
            self.queueOfflineCreate(
              tempId: optimisticId, content: content, parentId: nil, position: nil)
            // The create carries no due date, so queue the edit that applies
            // it. Replay maps the temp id onto the real one.
            if let due, !due.isEmpty {
              self.repository.enqueuePendingMutation(
                taskId: optimisticId, content: nil, due: due)
            }
          },
          whenOnline: {
            self.removeOptimisticTask(id: optimisticId)
            self.repository.errorMessage = "Error adding task: \(error.localizedDescription)"
          }
        )
      }
    }
  }
}
