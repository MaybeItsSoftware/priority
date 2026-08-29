import Foundation
import OSLog
import PriorityCore

/// Owns the network-facing surface of the coordinator: authentication, list
/// management, fetching tasks, the offline-mutation flush, and the
/// position/parent edits (move, indent, unindent) that need a serialised
/// reorder queue talking to the active sync plugin.
///
/// Owns the raw network/auth state directly via a strong `TaskRepository`
/// reference — `listId`, `errorMessage`, `activeCredentials`, and the active
/// sync plugin all come from there. The sibling managers it orchestrates
/// (kanban, timer, focus session, integrations, the root-view mode, the
/// navigation cursor) are reached through the `SyncHost` seam so this file
/// stays free of app-only types and can be exercised by
/// `PriorityAppLogicTests` against a stub host. `AppCoordinator` is the
/// production host; the reference is `weak` because it owns this service.
@MainActor
final class SyncService {
  private weak var host: (any SyncHost)?
  private let repository: TaskRepository
  /// Guards `flushPendingTaskMutations` against overlapping runs — see the
  /// comment at its top.
  private var isFlushingOfflineWork = false
  private let logger = Logger(
    subsystem: "uk.co.maybeitsadam.priority", category: "sync")

  init(host: any SyncHost, repository: TaskRepository) {
    self.host = host
    self.repository = repository
  }

  // MARK: - Authentication & Fetch

  func login() async -> Bool {
    await repository.login()
  }

  func fetchTopTask() async {
    guard let host else { return }
    if repository.canSyncRemotely && repository.listId.isEmpty { return }

    repository.errorMessage = nil
    let generation = repository.beginFetchGeneration()

    do {
      try await repository.withLoadingState {
        let response = try await repository.activeSyncPlugin.fetchOpenTasks(
          listId: repository.listId,
          credentials: repository.activeCredentials
        )

        // Nothing serialises the fetch callers, so responses can land out of
        // order. A newer fetch owns `tasks` from the moment it is issued;
        // applying this one on top of it would show an older list.
        guard repository.isLatestFetchGeneration(generation) else { return }

        // Tasks the user completed while this response was on the wire aren't
        // closed as far as it is concerned. Drop them, or completing a task
        // just as the popover opened put it straight back on screen.
        let fetchedTasks = repository.filteringLocallyCompletedTasks(
          from: response, generation: generation)

        // Read after the await: `tasks` is main-actor state, but a suspension
        // lets other main-actor work reshape it, and the timer remap needs the
        // shape we are actually replacing.
        let previousTasks = repository.tasks
        repository.tasks = fetchedTasks
        repository.markSyncSucceeded()
        repository.activeSyncPlugin.persistTaskCache(
          listId: repository.listId, tasks: fetchedTasks)
        repository.reconcilePriorityQueueWithOpenTasks()
        host.reconcilePendingObsidianSyncQueue(
          openTaskIds: Set(repository.tasks.map(\.id)),
          listId: repository.listId
        )
        if host.taskMoveMode == .kanbanColumn {
          host.clampKanbanSelection()
        } else if host.currentSiblingIndex >= fetchedTasks.count {
          host.currentSiblingIndex = 0
        }
        host.clampFocusSessionForTasks(fetchedTasks)
        host.reconcileTimersAfterFetch(previousTasks: previousTasks, openTasks: fetchedTasks)
        let latestOpenTaskIDs = Set(fetchedTasks.map(\.id))
        if let filterParentId = host.kanbanFilterParentId,
          !latestOpenTaskIDs.contains(filterParentId)
        {
          host.kanbanFilterParentId = nil
          if host.taskMoveMode == .kanbanColumn {
            host.currentParentId = 0
          }
        }
        if !repository.listId.isEmpty && repository.canAttemptLogin {
          host.markOnboardingCompleted()
        }
      }
    } catch CheckvistSessionError.authenticationUnavailable {
      repository.setAuthenticationRequiredErrorIfNeeded()
    } catch {
      logger.error("Fetch tasks failed: \(error.localizedDescription, privacy: .public)")
      repository.errorMessage = "Failed to fetch tasks: \(error.localizedDescription)"
    }
  }

  // MARK: - List Management

  func fetchLists() async -> Bool {
    await repository.fetchLists()
  }

  func loadCheckvistLists(assignFirstIfMissing: Bool = false) async -> Bool {
    await repository.loadCheckvistLists(assignFirstIfMissing: assignFirstIfMissing)
  }

  func switchCheckvistList(to rawListId: String) async {
    guard let host else { return }
    let trimmedListId = rawListId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedListId != repository.listId else { return }

    repository.listId = trimmedListId
    host.currentParentId = 0
    host.currentSiblingIndex = 0
    repository.clearPendingOfflineWork()
    host.kanbanFilterParentId = nil
    host.clearKanbanSelection()
    repository.errorMessage = nil
    await fetchTopTask()
  }

  func createCheckvistListAndSwitch(name: String) async -> Bool {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      repository.errorMessage = "List name cannot be empty."
      return false
    }

    repository.beginLoading()
    defer { repository.endLoading() }

    do {
      guard
        let createdList = try await repository.activeSyncPlugin.createList(
          name: trimmedName,
          credentials: repository.activeCredentials
        )
      else {
        repository.errorMessage = "Failed to create list."
        return false
      }

      _ = await fetchLists()
      selectList(createdList)
      repository.errorMessage = "Created and switched to list: \(createdList.name)"
      await fetchTopTask()
      return true
    } catch CheckvistSessionError.authenticationUnavailable {
      repository.setAuthenticationRequiredErrorIfNeeded()
      return false
    } catch {
      repository.errorMessage = "Failed to create list: \(error.localizedDescription)"
      return false
    }
  }

  func mergeOpenTasksBetweenLists(sourceListId: String, destinationListId: String) async -> Bool {
    let source = sourceListId.trimmingCharacters(in: .whitespacesAndNewlines)
    let destination = destinationListId.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !source.isEmpty, !destination.isEmpty else {
      repository.errorMessage = "Choose both source and destination lists."
      return false
    }
    guard source != destination else {
      repository.errorMessage = "Source and destination list must be different."
      return false
    }

    repository.beginLoading()
    defer { repository.endLoading() }

    do {
      let sourceTasks = try await repository.activeSyncPlugin.fetchOpenTasks(
        listId: source,
        credentials: repository.activeCredentials
      )
      guard !sourceTasks.isEmpty else {
        repository.errorMessage = "Source list has no open tasks to merge."
        return false
      }

      let orderedTasks = sourceTasks.sorted { lhs, rhs in
        let lhsLevel = lhs.level ?? 0
        let rhsLevel = rhs.level ?? 0
        if lhsLevel != rhsLevel { return lhsLevel < rhsLevel }

        let lhsParent = lhs.parentId ?? 0
        let rhsParent = rhs.parentId ?? 0
        if lhsParent != rhsParent { return lhsParent < rhsParent }

        return (lhs.position ?? Int.max) < (rhs.position ?? Int.max)
      }

      let migrationResult = try await copyTasks(orderedTasks, to: destination)

      if destination == repository.listId {
        await fetchTopTask()
      }

      repository.errorMessage =
        migrationResult.skippedCount > 0
        ? "Merged \(migrationResult.mergedCount) tasks (\(migrationResult.skippedCount) skipped)."
        : "Merged \(migrationResult.mergedCount) tasks."
      return true
    } catch CheckvistSessionError.authenticationUnavailable {
      repository.setAuthenticationRequiredErrorIfNeeded()
      return false
    } catch {
      repository.errorMessage = "Failed to merge lists: \(error.localizedDescription)"
      return false
    }
  }

  func selectList(_ list: CheckvistList) {
    repository.selectList(list)
  }

  func uploadOfflineTasksToCheckvist(destinationListId: String) async -> Bool {
    let destination = destinationListId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !destination.isEmpty else {
      repository.errorMessage = "Choose a Checkvist destination list."
      return false
    }

    let offlineTasks =
      (try? await repository.offlineSyncPlugin.fetchOpenTasks(
        listId: "", credentials: repository.activeCredentials)) ?? []
    guard !offlineTasks.isEmpty else {
      repository.errorMessage = "No offline tasks are available to upload."
      return false
    }

    let loginSucceeded = await login()
    guard loginSucceeded else { return false }

    repository.beginLoading()
    defer { repository.endLoading() }

    do {
      let migrationResult = try await copyTasks(offlineTasks, to: destination)

      if destination == repository.listId {
        await fetchTopTask()
      }

      repository.errorMessage =
        migrationResult.skippedCount > 0
        ? "Uploaded \(migrationResult.mergedCount) offline tasks (\(migrationResult.skippedCount) skipped)."
        : "Uploaded \(migrationResult.mergedCount) offline tasks."
      return true
    } catch CheckvistSessionError.authenticationUnavailable {
      repository.setAuthenticationRequiredErrorIfNeeded()
      return false
    } catch {
      repository.errorMessage = "Failed to upload offline tasks: \(error.localizedDescription)"
      return false
    }
  }

  private func copyTasks(_ sourceTasks: [CheckvistTask], to destinationListId: String) async throws
    -> (mergedCount: Int, skippedCount: Int)
  {
    try await repository.copyTasks(sourceTasks, to: destinationListId)
  }

  // MARK: - Offline Mutation Queue

  /// Replays offline-queued creates, deletes, actions, and updates against
  /// the active sync plugin. Creates run first to build a `tempId → realId`
  /// map; later queues resolve negative ids through it so a delete or close
  /// of an offline-created task hits the correct server task.
  ///
  /// Each item leaves the queue — memory *and* disk — only once the server has
  /// acknowledged it. A failure leaves it exactly where it was (re-filed under
  /// the real id if its create succeeded this round) and suppresses the final
  /// `fetchTopTask` so optimistic UI state survives until the next reconnect
  /// attempt. This ordering is the point: the previous version cleared the
  /// whole on-disk payload before issuing the first request, so quitting or
  /// crashing part-way through discarded every item that had not yet failed.
  /// The queue exists to survive exactly that, so it must outlive the replay.
  func flushPendingTaskMutations() async {
    let repo = repository
    guard repo.hasPendingOfflineWork else { return }
    // The queue is only emptied item by item now, so a second call arriving
    // while the first is still awaiting the network would replay the same
    // snapshot again. The old up-front `clearPendingOfflineWork()` made that
    // impossible by accident; this makes it impossible on purpose.
    guard !isFlushingOfflineWork else { return }
    isFlushingOfflineWork = true
    defer { isFlushingOfflineWork = false }

    let creates = repo.pendingTaskCreates
    let deletes = repo.pendingTaskDeletes
    let actions = repo.pendingTaskActions
    let mutations = repo.pendingTaskMutations

    var tempIdToRealId: [Int: Int] = [:]
    /// Temp ids whose create failed this round and was put back on the queue.
    /// Work that targets one of these must be re-queued against the *temp* id
    /// rather than dropped — the create will be retried on the next flush, so
    /// discarding the dependent delete/action/update would resurrect a task the
    /// user completed or deleted while offline.
    var requeuedCreateTempIds: Set<Int> = []
    var anyFailure = false

    /// Returns the id to send to the server, or `nil` when the caller should
    /// stop processing this item. `dropFromQueue` fires only for `.drop` — the
    /// create the item depended on is gone for good, so the work is moot and
    /// has to be taken off the queue explicitly. A `.requeue` needs no action:
    /// the item is still sitting on the queue under its temp id, which is
    /// exactly where the next flush expects to find it. Decision logic lives in
    /// `OfflineReplayPolicy` so it can be unit-tested.
    func resolveForReplay(_ id: Int, dropFromQueue: () -> Void) -> Int? {
      switch OfflineReplayPolicy.resolve(
        taskId: id,
        tempIdToRealId: tempIdToRealId,
        requeuedCreateTempIds: requeuedCreateTempIds
      ) {
      case .send(let taskId):
        return taskId
      case .requeue:
        anyFailure = true
        return nil
      case .drop:
        dropFromQueue()
        return nil
      }
    }

    for pending in creates {
      let resolvedParentId: Int?
      if let parentId = pending.parentId, parentId < 0 {
        guard let realParentId = tempIdToRealId[parentId] else {
          // Parent create failed earlier; can't create child without it. The
          // child is still on the queue — leaving it there is what lets a
          // future flush retry it once the parent eventually succeeds.
          requeuedCreateTempIds.insert(pending.tempId)
          anyFailure = true
          continue
        }
        resolvedParentId = realParentId
      } else {
        resolvedParentId = pending.parentId
      }

      do {
        if let newTask = try await repo.activeSyncPlugin.createTask(
          listId: repository.listId,
          content: pending.content,
          parentId: resolvedParentId,
          position: pending.position,
          credentials: repository.activeCredentials
        ) {
          // Off the queue only now that the server has acknowledged it.
          repo.removePendingCreate(tempId: pending.tempId)
          tempIdToRealId[pending.tempId] = newTask.id
          if let idx = repository.tasks.firstIndex(where: { $0.id == pending.tempId }) {
            repository.tasks[idx] = newTask
          }
        } else {
          requeuedCreateTempIds.insert(pending.tempId)
          anyFailure = true
        }
      } catch {
        requeuedCreateTempIds.insert(pending.tempId)
        anyFailure = true
        logger.error(
          "Offline create replay failed: \(error.localizedDescription, privacy: .public)")
      }
    }

    for tempOrRealId in deletes {
      guard
        let realId = resolveForReplay(
          tempOrRealId, dropFromQueue: { repo.removePendingDelete(tempOrRealId) })
      else {
        // Either the create is being retried (so the delete stays queued behind
        // it) or it is gone for good, in which case the delete was moot and has
        // just been dropped.
        continue
      }
      do {
        _ = try await repo.activeSyncPlugin.deleteTask(
          listId: repository.listId,
          taskId: realId,
          credentials: repository.activeCredentials)
        repo.removePendingDelete(tempOrRealId)
      } catch {
        repo.retargetPendingDelete(from: tempOrRealId, to: realId)
        anyFailure = true
        logger.error(
          "Offline delete replay failed: \(error.localizedDescription, privacy: .public)")
      }
    }

    for pending in actions {
      guard
        let realId = resolveForReplay(
          pending.taskId,
          dropFromQueue: {
            repo.removePendingAction(taskId: pending.taskId, action: pending.action)
          })
      else { continue }
      do {
        _ = try await repo.activeSyncPlugin.performTaskAction(
          listId: repository.listId,
          taskId: realId,
          action: pending.action,
          credentials: repository.activeCredentials)
        repo.removePendingAction(taskId: pending.taskId, action: pending.action)
      } catch {
        repo.retargetPendingAction(
          from: pending.taskId, to: realId, action: pending.action)
        anyFailure = true
        logger.error(
          "Offline action replay failed: \(error.localizedDescription, privacy: .public)")
      }
    }

    for (tempOrRealId, mutation) in mutations {
      guard
        let realId = resolveForReplay(
          tempOrRealId,
          dropFromQueue: { repo.removePendingMutation(taskId: tempOrRealId) })
      else { continue }
      do {
        _ = try await repo.activeSyncPlugin.updateTask(
          listId: repository.listId,
          taskId: realId,
          content: mutation.content,
          due: mutation.due,
          credentials: repository.activeCredentials)
        repo.removePendingMutation(taskId: tempOrRealId)
      } catch {
        repo.retargetPendingMutation(from: tempOrRealId, to: realId)
        anyFailure = true
        logger.error(
          "Offline update replay failed: \(error.localizedDescription, privacy: .public)")
      }
    }

    if !anyFailure {
      await fetchTopTask()
    }
  }

  // MARK: - Reorder

  func moveTask(_ task: CheckvistTask, direction: Int) async {
    guard let host else { return }
    guard direction == -1 || direction == 1 else { return }

    switch host.taskMoveMode {
    case .priorityQueue:
      movePriorityTask(task, direction: direction)
    case .kanbanColumn:
      host.moveTaskWithinKanbanColumn(taskId: task.id, direction: direction)
    case .dueDate:
      moveDueTaskByCopyingDate(task: task, direction: direction)
    case .siblingPosition:
      swapWithSiblingNeighbour(task: task, direction: direction)
    }
  }

  /// Position-based sibling swap. Moves the task one slot up/down within its
  /// parent's sibling list. Visible immediately in views sorted by position
  /// (All, Tags, sub-level scopes).
  private func swapWithSiblingNeighbour(task: CheckvistTask, direction: Int) {
    let siblings =
      repository.tasks.filter { ($0.parentId ?? 0) == (task.parentId ?? 0) }
    guard let idx = siblings.firstIndex(where: { $0.id == task.id }) else { return }
    let newIdx = idx + direction
    guard siblings.indices.contains(newIdx) else { return }
    let neighbour = siblings[newIdx]
    performSiblingPositionSwap(
      task: task, neighbour: neighbour, direction: direction, targetPosition: newIdx + 1
    )
  }

  /// In the Due view, Cmd+Up/Down copies the visible neighbour's due date so
  /// the task slides into a new bucket. After copy, also nudges position so
  /// the task lands above (Cmd+Up) or below (Cmd+Down) the neighbour —
  /// otherwise they share a bucket+date and the position-tiebreak could
  /// place the task on the wrong side of the neighbour.
  private func moveDueTaskByCopyingDate(task: CheckvistTask, direction: Int) {
    guard let host else { return }
    let visible = host.visibleTasks
    guard let idx = visible.firstIndex(where: { $0.id == task.id }) else { return }
    let newIdx = idx + direction
    guard visible.indices.contains(newIdx) else { return }
    let neighbour = visible[newIdx]

    let neighbourDue = neighbour.due ?? ""
    let taskDue = task.due ?? ""

    if neighbourDue != taskDue {
      let neighbourPos = neighbour.position ?? 1
      let newPosition = direction < 0 ? max(1, neighbourPos - 1) : neighbourPos + 1
      if let idx = repository.tasks.firstIndex(where: { $0.id == task.id }) {
        repository.tasks[idx] = taskWithPosition(repository.tasks[idx], position: newPosition)
      }
      host.applyOptimisticUpdate(task: task, content: nil, due: neighbourDue)
      enqueueReorderRequest(taskId: task.id, position: newPosition)
    } else if (task.parentId ?? 0) == (neighbour.parentId ?? 0) {
      swapWithSiblingNeighbour(task: task, direction: direction)
    }
  }

  /// Optimistic position swap of `task` and `neighbour` (same parent). Updates
  /// `tasks` in place and enqueues the server-side reorder.
  private func performSiblingPositionSwap(
    task: CheckvistTask, neighbour: CheckvistTask, direction: Int, targetPosition: Int
  ) {
    guard let host else { return }

    // Compute deterministic positions for both tasks. Don't rely on the
    // moving task's original position — if it was nil/sparse, copying it to
    // the neighbour would leave the comparator falling back to alphabetical
    // sort, which often matches the previous order and looks like no move
    // happened at all.
    let neighbourTargetPosition = max(1, targetPosition - direction)

    if let movingRange = host.subtreeBlockRange(for: task.id, in: repository.tasks),
      let neighbourRange = host.subtreeBlockRange(for: neighbour.id, in: repository.tasks)
    {
      var updated = repository.tasks
      let movingBlock = Array(updated[movingRange])
      updated.removeSubrange(movingRange)

      let insertIndex: Int
      if direction > 0 {
        // Neighbour was below; after removing our block, its end index shifts
        // left.
        insertIndex = neighbourRange.upperBound - movingBlock.count
      } else {
        // Neighbour was above; its range is unaffected by the removal.
        insertIndex = neighbourRange.lowerBound
      }
      updated.insert(contentsOf: movingBlock, at: max(0, min(updated.count, insertIndex)))

      if let movedIdx = updated.firstIndex(where: { $0.id == task.id }) {
        updated[movedIdx] = taskWithPosition(updated[movedIdx], position: targetPosition)
      }
      if let neighbourIdx = updated.firstIndex(where: { $0.id == neighbour.id }) {
        updated[neighbourIdx] = taskWithPosition(
          updated[neighbourIdx], position: neighbourTargetPosition)
      }

      repository.tasks = updated
      // Keep selection anchored to the moved task in the currently visible
      // list.
      if let visibleIdx = host.visibleTasks.firstIndex(where: { $0.id == task.id }) {
        host.currentSiblingIndex = visibleIdx
      }
    }

    enqueueReorderRequest(taskId: task.id, position: targetPosition)
  }

  /// Reorder within the priority view by swapping the visible neighbour's
  /// slot only when both tasks compete in the same priority queue (both
  /// absolute, or both scoped under the same parent). Unrelated tasks —
  /// different parent scopes, or one absolute and one scoped — don't have
  /// comparable rankings, so we leave them alone instead of stealing each
  /// other's slot.
  func movePriorityTask(_ task: CheckvistTask, direction: Int) {
    guard let host else { return }
    let visible = host.visibleTasks
    guard let idx = visible.firstIndex(where: { $0.id == task.id }) else { return }
    let newIdx = idx + direction
    guard visible.indices.contains(newIdx) else { return }
    let neighbour = visible[newIdx]

    let absoluteQueue = repository.absolutePriorityTaskIds
    let byParent = repository.priorityTaskIdsByParentId

    let taskAbs = absoluteQueue.firstIndex(of: task.id)
    let neighbourAbs = absoluteQueue.firstIndex(of: neighbour.id)

    if let i1 = taskAbs, let i2 = neighbourAbs {
      var queue = absoluteQueue
      queue.swapAt(i1, i2)
      repository.saveAbsolutePriorityQueue(queue)
      host.currentSiblingIndex = newIdx
      return
    }

    let taskScope = priorityScope(for: task.id, in: byParent)
    let neighbourScope = priorityScope(for: neighbour.id, in: byParent)

    if let (p1, i1) = taskScope, let (p2, i2) = neighbourScope, p1 == p2 {
      var updated = byParent
      var queue = updated[p1] ?? []
      queue.swapAt(i1, i2)
      updated[p1] = queue
      repository.savePriorityQueue(updated)
      host.currentSiblingIndex = newIdx
    }
  }

  private func priorityScope(
    for taskId: Int, in byParent: [Int: [Int]]
  ) -> (parentId: Int, index: Int)? {
    for (parentId, ids) in byParent {
      if let idx = ids.firstIndex(of: taskId) { return (parentId, idx) }
    }
    return nil
  }

  private func taskWithPosition(_ task: CheckvistTask, position: Int?) -> CheckvistTask {
    CheckvistTask(
      id: task.id,
      content: task.content,
      status: task.status,
      due: task.due,
      position: position,
      parentId: task.parentId,
      level: task.level
    )
  }

  // MARK: - Reorder Queue

  private func enqueueReorderRequest(taskId: Int, position: Int) {
    repository.reorderQueue.enqueue(taskId: taskId, position: position)
    startReorderSyncIfNeeded()
  }

  private func startReorderSyncIfNeeded() {
    guard !repository.reorderQueue.isSyncing else { return }

    let repository = repository
    let task = Task { [weak self] in
      guard let self else { return }
      var hadFailure = false

      while true {
        let nextRequest: ReorderQueue.Request? = await MainActor.run {
          repository.reorderQueue.dequeueNext()
        }

        guard let nextRequest else { break }
        let success = await self.commitReorderRequest(
          taskId: nextRequest.taskId, position: nextRequest.position)
        if !success { hadFailure = true }
      }

      await MainActor.run {
        repository.reorderQueue.setSyncTask(nil)
        if hadFailure { self.scheduleReorderResync() }
        if !repository.reorderQueue.pending.isEmpty {
          self.startReorderSyncIfNeeded()
        }
      }
    }
    repository.reorderQueue.setSyncTask(task)
  }

  private func commitReorderRequest(taskId: Int, position: Int) async -> Bool {
    do {
      let success = try await repository.activeSyncPlugin.moveTask(
        listId: repository.listId,
        taskId: taskId,
        position: position,
        credentials: repository.activeCredentials
      )
      if !success {
        repository.errorMessage = "Failed to move task."
        return false
      }
      return true
    } catch CheckvistSessionError.authenticationUnavailable {
      return false
    } catch {
      repository.errorMessage = "Error: \(error.localizedDescription)"
      return false
    }
  }

  private func scheduleReorderResync() {
    let repository = repository
    let task = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 600_000_000)
      guard let self else { return }
      await self.fetchTopTask()
      repository.reorderQueue.setResyncTask(nil)
    }
    repository.reorderQueue.setResyncTask(task)
  }

  // MARK: - Indent / Unindent

  /// Put the cursor back on a task that has just moved in the tree.
  ///
  /// Selection is an index into the *visible* list, so reparenting a task
  /// leaves that index pointing at whatever has taken its place — indenting
  /// with Tab appeared to lose focus for exactly this reason. The reorder path
  /// has anchored selection this way since it was written; the indent pair
  /// never did.
  private func anchorSelection(to taskId: Int) {
    guard let host, let index = host.visibleTasks.firstIndex(where: { $0.id == taskId })
    else { return }
    host.currentSiblingIndex = index
  }

  func indentTask(_ task: CheckvistTask) async {
    let siblings =
      repository.tasks.filter { ($0.parentId ?? 0) == (task.parentId ?? 0) }
    guard let idx = siblings.firstIndex(where: { $0.id == task.id }), idx > 0 else { return }
    let newParent = siblings[idx - 1]
    // The task is about to move underneath a sibling. Open that sibling, or
    // indenting reads as the task vanishing.
    repository.setExpanded(true, taskId: newParent.id)

    await repository.runBooleanMutation(
      failureMessage: "Failed to indent task.",
      errorMessageBuilder: { "Error indenting task: \($0.localizedDescription)" },
      action: {
        try await repository.activeSyncPlugin.reparentTask(
          listId: repository.listId,
          taskId: task.id,
          parentId: newParent.id,
          credentials: repository.activeCredentials
        )
      },
      onSuccess: { [weak self] in
        await self?.fetchTopTask()
        self?.anchorSelection(to: task.id)
      }
    )
  }

  func unindentTask(_ task: CheckvistTask) async {
    guard let parentId = task.parentId, parentId != 0 else { return }
    guard let parent = repository.tasks.first(where: { $0.id == parentId }) else { return }
    let newParentId = parent.parentId ?? 0

    await repository.runBooleanMutation(
      failureMessage: "Failed to unindent task.",
      errorMessageBuilder: { "Error unindenting task: \($0.localizedDescription)" },
      action: {
        try await repository.activeSyncPlugin.reparentTask(
          listId: repository.listId,
          taskId: task.id,
          parentId: newParentId == 0 ? nil : newParentId,
          credentials: repository.activeCredentials
        )
      },
      onSuccess: { [weak self] in
        await self?.fetchTopTask()
        self?.anchorSelection(to: task.id)
      }
    )
  }
}

// MARK: - Conflict Resolution & Sync Strategies
extension SyncService {
  func overwriteLocalWithRemoteTasks() async {
    let remoteTasks = repository.tasks
    let nextId = (remoteTasks.map(\.id).max() ?? 0) + 1
    let payload = OfflineTaskStorePayload(
      openTasks: remoteTasks, archivedTasks: [], nextTaskId: nextId)
    repository.localTaskStore.save(payload)
    repository.errorMessage = "Successfully overwrote local tasks with remote list."
  }

  func overwriteRemoteWithLocalTasks(destinationListId: String) async -> Bool {
    let loginSucceeded = await login()
    guard loginSucceeded else { return false }

    repository.beginLoading()
    defer { repository.endLoading() }

    do {
      // 1. Snapshot the remote tasks that this overwrite will replace.
      let supersededRemoteTasks = try await repository.activeSyncPlugin
        .fetchOpenTasks(
          listId: destinationListId,
          credentials: repository.activeCredentials
        )

      // 2. Upload the local tasks *before* deleting anything. Deleting first
      //    meant a failure partway through the upload left the remote list
      //    destroyed with nothing to restore from.
      let localTasks = repository.localTaskStore.load().openTasks
      _ = try await repository.copyTasks(localTasks, to: destinationListId)

      // 3. Now retire the superseded tasks. A failure here is non-fatal: the
      //    uploaded copy is already in place, so report the leftovers rather
      //    than aborting and leaving the list in a half-known state.
      var undeletedCount = 0
      for task in supersededRemoteTasks {
        do {
          let deleted = try await repository.activeSyncPlugin.deleteTask(
            listId: destinationListId,
            taskId: task.id,
            credentials: repository.activeCredentials
          )
          if !deleted { undeletedCount += 1 }
        } catch {
          undeletedCount += 1
          logger.error(
            "Overwrite-remote delete failed: \(error.localizedDescription, privacy: .public)")
        }
      }

      // 4. Refresh local tasks
      if destinationListId == repository.listId {
        await fetchTopTask()
      }

      repository.errorMessage =
        undeletedCount > 0
        ? "Overwrote remote list with local tasks (\(undeletedCount) old tasks could not be removed)."
        : "Successfully overwrote remote list with local tasks."
      return true
    } catch CheckvistSessionError.authenticationUnavailable {
      repository.setAuthenticationRequiredErrorIfNeeded()
      return false
    } catch {
      repository.errorMessage = "Failed to overwrite remote: \(error.localizedDescription)"
      return false
    }
  }
}
