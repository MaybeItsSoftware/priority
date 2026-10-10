import Foundation

/// The optimistic content/due edit the legacy board and the due-date reorder
/// shared.
///
/// Split out of `TaskMutationService.swift` only to keep both files under the
/// SwiftLint length limits; it is the same service and shares its private
/// helpers (`restoreTask`, `resolveMutationFailure`), which is why this is an
/// extension rather than a new type.
extension TaskMutationService {
  // MARK: - Board Mutations
  //
  // This arrived here from `AppCoordinator`, which was the last place still
  // hand-rolling the optimistic-mutation dance. It had drifted from the shared
  // version while it was up there: it wrote `pendingTaskMutations` directly
  // and so never reached disk. Routing it through `resolveMutationFailure` and
  // the repository's write-through enqueues is most of the reason to move it.

  /// Applies a content/due edit locally at once and syncs it in the
  /// background, rolling back if the server rejects it.
  ///
  /// Used by `SyncService`'s due-date reorder, which moves a task by copying
  /// its neighbour's date.
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
}
