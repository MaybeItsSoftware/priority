import Foundation
import OSLog

/// Owns task mutations: mark-done / reopen / invalidate, edit, add (sibling
/// or child), delete, the QuickAdd flow, and the recurrence cross-cutting that
/// fires the next occurrence after a recurring task is closed.
///
/// Owns its raw task/auth state directly via a strong `TaskRepository`
/// reference (`listId`, `errorMessage`, `activeCredentials`, the active sync
/// plugin). Everything else — selection, undo, quick-entry focus, recurrence
/// rules, the completion haptics — goes through the `TaskMutationHost` seam so
/// this file stays free of AppKit and SwiftUI and can be exercised by
/// `PriorityAppLogicTests` against a stub host. `AppCoordinator` is the
/// production host; the reference is `weak` because it owns this service.
@MainActor
final class TaskMutationService {
  // Internal rather than private only because `TaskMutationService+Board.swift`
  // is a second file of the same type, and Swift's `private` is file-scoped.
  // Nothing outside this service should touch either.
  weak var host: (any TaskMutationHost)?
  let repository: TaskRepository

  init(host: any TaskMutationHost, repository: TaskRepository) {
    self.host = host
    self.repository = repository
  }

  // MARK: - Failure Handling

  /// The single decision shared by every optimistic mutation when its server
  /// call throws: if the network is unreachable, keep the optimistic state and
  /// queue the work for replay (`whenOffline`); otherwise treat it as a genuine
  /// failure (`whenOnline`) — typically roll back the optimistic change and set
  /// an error message. Each caller supplies its own offline/online specifics;
  /// this only owns the reachability branch so it isn't re-derived per site.
  func resolveMutationFailure(
    whenOffline: () -> Void,
    whenOnline: () -> Void
  ) {
    if repository.isNetworkReachable {
      whenOnline()
    } else {
      whenOffline()
    }
  }

  // MARK: - Mark Done / Reopen / Invalidate

  /// Tasks with a status change already running, animation included.
  ///
  /// Mark-done spends ~200ms on the completion feedback before the request even
  /// goes out, and the row stays selected throughout, so a second press of a
  /// key as quick as Space landed inside that window and closed the same task
  /// twice: two day-log entries for one completion, and — worse — two next
  /// occurrences for a recurring task. Key-repeat was already filtered in the
  /// router; two deliberate presses were not.
  private var taskIdsWithStatusChangeInFlight: Set<Int> = []

  /// Runs `body` unless a status change is already in flight for `taskId`.
  /// Shared across mark-done/reopen/invalidate so they can't overlap on one
  /// task either.
  private func withStatusChangeClaim(on taskId: Int, _ body: () async -> Void) async {
    guard taskIdsWithStatusChangeInFlight.insert(taskId).inserted else { return }
    defer { taskIdsWithStatusChangeInFlight.remove(taskId) }
    await body()
  }

  func markCurrentTaskDone() async {
    guard let host, let task = host.currentTask else { return }

    await withStatusChangeClaim(on: task.id) {
      // The host runs the haptic/strikethrough sequence. It returns false when
      // the user navigated away or switched tasks mid-animation, which must
      // cancel the close rather than fire it late.
      guard await host.runTaskCompletionFeedback(taskId: task.id) else { return }

      await self.taskAction(task, endpoint: "close")
      await self.createNextOccurrence(for: task)
    }
  }

  func reopenCurrentTask() async {
    guard let host, let task = host.currentTask else { return }
    await withStatusChangeClaim(on: task.id) {
      await self.taskAction(task, endpoint: "reopen")
    }
  }

  func invalidateCurrentTask() async {
    guard let host, let task = host.currentTask else { return }
    await withStatusChangeClaim(on: task.id) {
      await self.taskAction(task, endpoint: "invalidate")
    }
  }

  /// POST to a Checkvist task action endpoint (close, reopen, invalidate).
  func taskAction(_ task: CheckvistTask, endpoint: String, isUndo: Bool = false) async {
    guard let host else { return }

    if !isUndo {
      if endpoint == "close" {
        host.lastUndoableAction = .markDone(taskId: task.id)
      } else if endpoint == "invalidate" {
        host.lastUndoableAction = .invalidate(taskId: task.id)
      }
    }

    guard let action = CheckvistTaskAction(rawValue: endpoint) else { return }

    // Undoing a close reopens a task whose id we are still hiding from fetch
    // responses. Lift that first, or the refetch below would filter the task
    // the user just asked for straight back out.
    if action == .reopen {
      repository.unsuppressLocallyCompletedTasks([task.id])
    }

    let ancestorTaskIDsToKeepOpen =
      (!isUndo && endpoint == "close") ? ancestorTaskIDs(for: task, in: repository.tasks) : []

    let optimisticSnapshot: OptimisticCompletionSnapshot? =
      (!isUndo && (endpoint == "close" || endpoint == "invalidate"))
      ? applyOptimisticCompletion(for: task.id) : nil

    do {
      let success = try await repository.activeSyncPlugin.performTaskAction(
        listId: repository.listId,
        taskId: task.id,
        action: action,
        credentials: repository.activeCredentials
      )
      if success {
        host.recordDayLogTaskAction(taskId: task.id, title: task.content, action: action)
        await reopenAncestorTasks(ancestorTaskIDsToKeepOpen)
        await host.fetchTopTask()
      } else {
        if let optimisticSnapshot {
          restoreTasksSnapshot(optimisticSnapshot)
        }
        repository.errorMessage = "Failed to \(endpoint) task."
      }
    } catch {
      resolveMutationFailure(
        whenOffline: {
          // Logged here as well as on the success path: an offline close is
          // still something the user did today, and waiting for the replay to
          // land would drop it out of the day it belongs to.
          host.recordDayLogTaskAction(taskId: task.id, title: task.content, action: action)
          self.queueOfflineTaskAction(
            taskId: task.id, action: action, ancestorIds: ancestorTaskIDsToKeepOpen)
        },
        whenOnline: {
          if let optimisticSnapshot {
            self.restoreTasksSnapshot(optimisticSnapshot)
          }
          // The auth-unavailable case here rolls back silently (no message);
          // any other error surfaces a generic message.
          if case CheckvistSessionError.authenticationUnavailable = error {
            return
          }
          repository.errorMessage = "Error: \(error.localizedDescription)"
        }
      )
    }
  }

  /// Keep the optimistic close/reopen/invalidate in the UI and stash it for
  /// replay on reconnect. Ancestor reopens (used to defeat Checkvist's auto-
  /// complete-parent cascade) are queued too so the same reconciliation runs
  /// once we're back online.
  private func queueOfflineTaskAction(
    taskId: Int, action: CheckvistTaskAction, ancestorIds: [Int]
  ) {
    repository.enqueuePendingAction(
      PendingTaskAction(taskId: taskId, action: action))
    for ancestorId in ancestorIds {
      repository.enqueuePendingAction(
        PendingTaskAction(taskId: ancestorId, action: .reopen))
    }
    repository.errorMessage = "Offline — will sync when connected."
  }

  // MARK: - Update

  func updateTask(
    task: CheckvistTask, content: String? = nil, due: String? = nil, isUndo: Bool = false
  ) async {
    guard let host else { return }

    if !isUndo {
      host.lastUndoableAction = .update(
        taskId: task.id, oldContent: task.content, oldDue: task.due)
    }

    // Optimistic local update so UI reflects the change immediately.
    guard let index = repository.tasks.firstIndex(where: { $0.id == task.id }) else {
      repository.errorMessage = "Task not found."
      return
    }
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

    do {
      let success = try await repository.activeSyncPlugin.updateTask(
        listId: repository.listId,
        taskId: task.id,
        content: content,
        due: due,
        credentials: repository.activeCredentials
      )
      if success {
        await host.fetchTopTask()
      } else {
        restoreTask(originalTask)
        repository.errorMessage = "Failed to update task."
      }
    } catch {
      resolveMutationFailure(
        whenOffline: {
          repository.enqueuePendingMutation(
            taskId: task.id, content: content, due: due)
          repository.errorMessage = "Offline — will sync when connected."
        },
        whenOnline: {
          self.restoreTask(originalTask)
          if case CheckvistSessionError.authenticationUnavailable = error {
            repository.setAuthenticationRequiredErrorIfNeeded()
          } else {
            repository.errorMessage = "Error: \(error.localizedDescription)"
          }
        }
      )
    }
  }

  // MARK: - Add

  func addTask(
    content: String,
    insertAfterTask: CheckvistTask? = nil,
    insertAtTopOfCurrentLevel: Bool = false,
    insertsAbove: Bool = false
  ) async {
    guard let host else { return }

    let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedContent.isEmpty else {
      repository.errorMessage = "Task content cannot be empty."
      return
    }

    guard !repository.listId.isEmpty else {
      repository.errorMessage = "Choose a Checkvist list in Preferences to add tasks."
      return
    }

    let target = insertAfterTask ?? host.currentTask

    // A sibling belongs beside the row you are on, which is not the same thing
    // as the top of the scope. Since the list became an outline the selected
    // row can sit several levels inside the scope while `currentParentId`
    // still names the scope itself, so taking the parent from the scope sent
    // every add under a nested row up to the root. Add-to-top is the one case
    // that really does mean the current level, by name.
    let parentIdForNewTask: Int
    if insertAtTopOfCurrentLevel || target == nil {
      parentIdForNewTask = host.currentParentId
    } else {
      parentIdForNewTask = target?.parentId ?? 0
    }
    let parentIdForCreate = parentIdForNewTask == 0 ? nil : parentIdForNewTask

    let optimisticTask = insertOptimisticSiblingTask(
      content: trimmedContent,
      afterTask: insertAfterTask,
      parentId: parentIdForNewTask,
      insertAtTopOfCurrentLevel: insertAtTopOfCurrentLevel,
      insertsAbove: insertsAbove
    )
    let optimisticTaskId = optimisticTask.id

    repository.beginLoading()
    defer { repository.endLoading() }
    repository.errorMessage = nil

    // Find current position to insert right below.
    var apiPosition = 0
    if insertAtTopOfCurrentLevel {
      apiPosition = 1
    } else if let current = target {
      // Checkvist positions are 1-based, so inserting *at* the target's
      // position pushes it down and takes its place — which is what "above"
      // means. Below is the same number plus one.
      let offset = insertsAbove ? 0 : 1
      if let targetPos = current.position {
        apiPosition = targetPos + offset
      } else {
        // Positions are per-parent, so the fallback has to count the target's
        // own siblings rather than the scope's.
        let siblings =
          repository.tasks.filter { ($0.parentId ?? 0) == parentIdForNewTask }
        if let idx = siblings.firstIndex(where: { $0.id == current.id }) {
          apiPosition = idx + 1 + offset
        }
      }
    } else {
      apiPosition = 1
    }

    let positionForCreate: Int? = apiPosition > 0 ? apiPosition : nil

    do {
      let newTask = try await repository.activeSyncPlugin.createTask(
        listId: repository.listId,
        content: trimmedContent,
        parentId: parentIdForCreate,
        position: positionForCreate,
        credentials: repository.activeCredentials
      )
      if let newTask {
        host.lastUndoableAction = .add(taskId: newTask.id)
        await host.fetchTopTask()
      } else {
        removeOptimisticTask(id: optimisticTaskId)
        repository.errorMessage = "Failed to add task."
      }
    } catch {
      resolveMutationFailure(
        whenOffline: {
          self.queueOfflineCreate(
            tempId: optimisticTaskId,
            content: trimmedContent,
            parentId: parentIdForCreate,
            position: positionForCreate)
        },
        whenOnline: {
          self.removeOptimisticTask(id: optimisticTaskId)
          if case CheckvistSessionError.authenticationUnavailable = error {
            repository.setAuthenticationRequiredErrorIfNeeded()
          } else {
            repository.errorMessage = "Error adding task: \(error.localizedDescription)"
          }
        }
      )
    }
  }

  /// Keeps the optimistic task in `tasks` and queues a create to fire on
  /// reconnect. Undo points at the temp id so a subsequent undo can either
  /// cancel the queued create or, after replay, delete the real task.
  func queueOfflineCreate(
    tempId: Int, content: String, parentId: Int?, position: Int?
  ) {
    repository.enqueuePendingCreate(
      PendingTaskCreate(
        tempId: tempId, content: content, parentId: parentId, position: position))
    host?.lastUndoableAction = .add(taskId: tempId)
    repository.errorMessage = "Offline — will sync when connected."
  }

  func addTaskAsChild(content: String, parentId: Int) async {
    guard let host else { return }

    let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedContent.isEmpty else {
      repository.errorMessage = "Task content cannot be empty."
      return
    }

    guard !repository.listId.isEmpty else {
      repository.errorMessage = "Choose a Checkvist list in Preferences to add tasks."
      return
    }
    let optimisticTask = insertOptimisticChildTask(content: trimmedContent, parentId: parentId)
    let optimisticTaskId = optimisticTask.id

    repository.beginLoading()
    defer { repository.endLoading() }
    repository.errorMessage = nil

    do {
      let newTask = try await repository.activeSyncPlugin.createTask(
        listId: repository.listId,
        content: trimmedContent,
        parentId: parentId,
        position: 1,
        credentials: repository.activeCredentials
      )
      if let newTask {
        host.lastUndoableAction = .add(taskId: newTask.id)
        await host.fetchTopTask()
      } else {
        removeOptimisticTask(id: optimisticTaskId)
        repository.errorMessage = "Failed to add task."
      }
    } catch {
      resolveMutationFailure(
        whenOffline: {
          self.queueOfflineCreate(
            tempId: optimisticTaskId, content: trimmedContent, parentId: parentId, position: 1)
        },
        whenOnline: {
          self.removeOptimisticTask(id: optimisticTaskId)
          if case CheckvistSessionError.authenticationUnavailable = error {
            repository.setAuthenticationRequiredErrorIfNeeded()
          } else {
            repository.errorMessage = "Error: \(error.localizedDescription)"
          }
        }
      )
    }
  }

  // MARK: - Delete

  func deleteTask(_ task: CheckvistTask, isUndo: Bool = false) async {
    guard let host else { return }

    if !isUndo {
      // Clear undo history since we don't support recovering hard-deleted
      // tasks yet.
      host.lastUndoableAction = nil
    }

    // If the task is still a queued offline create, cancel that create
    // instead of round-tripping a create+delete through the server.
    if repository.cancelPendingCreate(tempId: task.id) {
      _ = applyOptimisticCompletion(for: task.id)
      host.reconcilePendingObsidianSyncQueue(
        openTaskIds: Set(repository.tasks.map(\.id)),
        listId: repository.listId
      )
      return
    }

    guard let optimisticSnapshot = applyOptimisticCompletion(for: task.id) else {
      repository.errorMessage = "Task not found."
      return
    }
    host.reconcilePendingObsidianSyncQueue(
      openTaskIds: Set(repository.tasks.map(\.id)),
      listId: repository.listId
    )

    let listId = repository.listId
    let credentials = repository.activeCredentials
    let plugin = repository.activeSyncPlugin
    let taskId = task.id

    Task { [weak self] in
      do {
        let success = try await plugin.deleteTask(
          listId: listId,
          taskId: taskId,
          credentials: credentials
        )
        if !success {
          await MainActor.run {
            guard let self else { return }
            self.restoreTasksSnapshot(optimisticSnapshot)
            self.repository.errorMessage = "Failed to delete task."
          }
        }
      } catch {
        await MainActor.run {
          guard let self else { return }
          self.resolveMutationFailure(
            whenOffline: {
              self.repository.enqueuePendingDelete(taskId)
              self.repository.errorMessage = "Offline — will sync when connected."
            },
            whenOnline: {
              self.restoreTasksSnapshot(optimisticSnapshot)
              if case CheckvistSessionError.authenticationUnavailable = error {
                self.repository.setAuthenticationRequiredErrorIfNeeded()
              } else {
                self.repository.errorMessage = "Error: \(error.localizedDescription)"
              }
            }
          )
        }
      }
    }
  }

  // MARK: - Quick Add

  /// Returns true when QuickAdd was successfully primed (focus moved to the
  /// entry field). Returns false when the user has chosen specific-parent
  /// mode but hasn't configured a parent task ID yet — caller leaves focus
  /// alone in that case.
  func beginQuickAddEntry(preferSpecificLocation: Bool? = nil) -> Bool {
    guard let host else { return false }
    let useSpecificLocation =
      preferSpecificLocation ?? host.quickAddPrefersSpecificLocation
    if useSpecificLocation && host.quickAddSpecificParentTaskId == nil {
      repository.errorMessage = "Set a valid Quick Add parent task ID in Preferences first."
      return false
    }

    host.beginQuickAddEntry(useSpecificLocation: useSpecificLocation)
    return true
  }

  func setQuickAddSpecificLocationToCurrentTask() {
    guard let host else { return }
    guard let currentTask = host.currentTask else {
      repository.errorMessage = "No task selected."
      return
    }
    host.setQuickAddSpecificParentTask(id: currentTask.id)
    repository.errorMessage = nil
  }

  func submitQuickAddTask(content: String, useSpecificLocation: Bool) async {
    guard let host else { return }
    let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedContent.isEmpty else { return }

    let parentTaskId: Int?
    if useSpecificLocation {
      guard let specificTaskId = host.quickAddSpecificParentTaskId else {
        repository.errorMessage = "Set a valid Quick Add parent task ID in Preferences first."
        return
      }
      parentTaskId = specificTaskId
    } else {
      parentTaskId = nil
    }

    guard !repository.listId.isEmpty else {
      repository.errorMessage = "Choose a Checkvist list in Preferences to add tasks."
      return
    }

    repository.beginLoading()
    defer { repository.endLoading() }
    repository.errorMessage = nil

    do {
      let createdTask = try await repository.activeSyncPlugin.createTask(
        listId: repository.listId,
        content: normalizedContent,
        parentId: parentTaskId,
        position: 1,
        credentials: repository.activeCredentials
      )
      guard let createdTask else {
        repository.errorMessage = "Quick add failed."
        return
      }
      host.lastUndoableAction = .add(taskId: createdTask.id)
      await host.fetchTopTask()
      host.finishQuickAddEntry()
    } catch {
      resolveMutationFailure(
        whenOffline: {
          self.finishQuickAddOffline(content: normalizedContent, parentId: parentTaskId)
        },
        whenOnline: {
          if case CheckvistSessionError.authenticationUnavailable = error {
            repository.setAuthenticationRequiredErrorIfNeeded()
          } else {
            repository.errorMessage = "Quick add failed: \(error.localizedDescription)"
          }
        }
      )
    }
  }

  /// Quick add doesn't insert an optimistic task on the success path (it
  /// relies on the subsequent fetch to surface the new task). When offline
  /// there's no fetch to do, so insert one ourselves and queue the create.
  private func finishQuickAddOffline(content: String, parentId: Int?) {
    guard let host else { return }
    let optimisticTask = CheckvistTask(
      id: nextOptimisticTaskId(),
      content: content,
      status: 0,
      due: nil,
      position: nil,
      parentId: parentId,
      level: nil
    )
    repository.tasks.append(optimisticTask)
    queueOfflineCreate(
      tempId: optimisticTask.id, content: content, parentId: parentId, position: 1)
    host.finishQuickAddEntry()
  }

  // MARK: - Recurrence (cross-cutting: recurrence + task CRUD)

  /// Call after a recurring task is closed. Adds a sibling task with the next
  /// due date and transfers the recurrence rule to the new task.
  func createNextOccurrence(for completedTask: CheckvistTask) async {
    guard let host else { return }
    guard let result = host.nextOccurrence(for: completedTask) else {
      if host.hasRecurrenceRule(forTaskId: completedTask.id) {
        repository.errorMessage = "Could not calculate next occurrence for recurring task."
      }
      return
    }

    let completedTaskId = completedTask.id
    // Snapshot ids so the new occurrence can be identified by identity below.
    let taskIdsBeforeAdd = Set(repository.tasks.map(\.id))

    // Add the next sibling task with the same content.
    await addTask(
      content: completedTask.content,
      insertAfterTask: completedTask
    )

    // After addTask + fetchTopTask, find the newly created task. Matching on
    // content alone picked an arbitrary task when two siblings shared a title —
    // and then moved the recurrence rule onto the wrong one. The id has to be
    // new; content and "has no rule yet" stay as guards in case the refetch
    // brought in unrelated tasks created elsewhere.
    if let newTask = repository.tasks.first(where: {
      !taskIdsBeforeAdd.contains($0.id)
        && $0.content == completedTask.content
        && $0.id != completedTaskId
        && !host.hasRecurrenceRule(forTaskId: $0.id)
    }) {
      await updateTask(task: newTask, due: result.dueDateString)
      host.transferRecurrenceRule(
        fromTaskId: completedTaskId, toTaskId: newTask.id, rule: result.savedRule)
    } else {
      host.clearRecurrenceRule(forTaskId: completedTaskId)
    }
  }

  // MARK: - Optimistic Updates

  /// - Parameter parentId: the parent the new row is being added under, as
  ///   resolved by the caller — the row's own parent for a sibling add, the
  ///   scope for an add-to-top. 0 for the list root.
  private func insertOptimisticSiblingTask(
    content: String,
    afterTask: CheckvistTask?,
    parentId: Int,
    insertAtTopOfCurrentLevel: Bool = false,
    insertsAbove: Bool = false
  ) -> CheckvistTask {
    guard let host else {
      return CheckvistTask(
        id: nextOptimisticTaskId(), content: content, status: 0, due: nil,
        position: nil, parentId: parentId == 0 ? nil : parentId, level: nil)
    }

    let optimisticTask = CheckvistTask(
      id: nextOptimisticTaskId(),
      content: content,
      status: 0,
      due: nil,
      position: nil,
      parentId: parentId == 0 ? nil : parentId,
      level: nil
    )

    var insertIndex = repository.tasks.endIndex
    if insertAtTopOfCurrentLevel {
      if parentId == 0 {
        insertIndex =
          repository.tasks.firstIndex(where: { ($0.parentId ?? 0) == 0 })
          ?? repository.tasks.endIndex
      } else if let parentRawIndex = repository.tasks.firstIndex(where: {
        $0.id == parentId
      }) {
        insertIndex = parentRawIndex + 1
      }
    } else if let target = afterTask,
      let rawIndex = repository.tasks.firstIndex(where: { $0.id == target.id })
    {
      if insertsAbove {
        // The target's own slot. No subtree walk: we are landing in front of
        // the target, and whatever hangs off it stays behind it.
        insertIndex = rawIndex
      } else {
        // Past the target *and* everything nested under it, or the new sibling
        // lands between a parent and its children.
        var endIndex = rawIndex + 1
        while endIndex < repository.tasks.count
          && host.isDescendant(repository.tasks[endIndex], of: target.id)
        {
          endIndex += 1
        }
        insertIndex = endIndex
      }
    }

    if insertIndex <= repository.tasks.endIndex {
      repository.tasks.insert(optimisticTask, at: insertIndex)
    } else {
      repository.tasks.append(optimisticTask)
    }

    // The outline, not the level: the selection indexes into the rendered
    // rows, and a row added beside a nested one is not in `currentLevelTasks`
    // at all — so looking there left the cursor on whichever row happened to
    // hold that index.
    if let insertedIndex = host.visibleTasks.firstIndex(where: {
      $0.id == optimisticTask.id
    }) {
      host.currentSiblingIndex = insertedIndex
    }
    return optimisticTask
  }

  private func insertOptimisticChildTask(content: String, parentId: Int) -> CheckvistTask {
    let optimisticTask = CheckvistTask(
      id: nextOptimisticTaskId(),
      content: content,
      status: 0,
      due: nil,
      position: nil,
      parentId: parentId,
      level: nil
    )

    if let parentRawIdx = repository.tasks.firstIndex(where: { $0.id == parentId }) {
      repository.tasks.insert(optimisticTask, at: parentRawIdx + 1)
    } else {
      repository.tasks.append(optimisticTask)
    }
    return optimisticTask
  }

  /// Rolls a task back to `originalTask`, re-finding its row by id.
  ///
  /// Never reuse an index captured before an `await`. `tasks` is main-actor
  /// state, but a suspension lets other main-actor work interleave:
  /// `fetchTopTask` replaces the array wholesale and `applyOptimisticCompletion`
  /// removes a whole subtree, so by the time a rollback runs the old index can
  /// point at a different task or past the end of the array.
  func restoreTask(_ originalTask: CheckvistTask) {
    guard let index = repository.tasks.firstIndex(where: { $0.id == originalTask.id })
    else { return }
    repository.tasks[index] = originalTask
  }

  func removeOptimisticTask(id: Int) {
    guard let index = repository.tasks.firstIndex(where: { $0.id == id })
    else { return }
    repository.tasks.remove(at: index)
    host?.clampSelectionToVisibleRange()
  }

  fileprivate struct OptimisticCompletionSnapshot {
    /// The subtree that was lifted out of `tasks`, in order.
    let removedTasks: [CheckvistTask]
    /// Id of the row that sat immediately above the removed block, or `nil` if
    /// the block was at the top. Re-found by id on restore, so the subtree goes
    /// back where it belongs even if the list moved underneath.
    let precedingTaskId: Int?
    let priorityTaskIdsByParentId: [Int: [Int]]
    let absolutePriorityTaskIds: [Int]
    let timerByTaskId: [Int: TimeInterval]
    let pendingObsidianSyncTaskIds: [Int]

    var removedTaskIds: Set<Int> { Set(removedTasks.map(\.id)) }
  }

  private func applyOptimisticCompletion(for taskId: Int) -> OptimisticCompletionSnapshot? {
    guard let host else { return nil }
    guard let removingRange = host.subtreeBlockRange(for: taskId, in: repository.tasks)
    else { return nil }
    let removedTasks = Array(repository.tasks[removingRange])
    let snapshot = OptimisticCompletionSnapshot(
      removedTasks: removedTasks,
      precedingTaskId: removingRange.lowerBound > 0
        ? repository.tasks[removingRange.lowerBound - 1].id : nil,
      priorityTaskIdsByParentId: repository.priorityTaskIdsByParentId,
      absolutePriorityTaskIds: repository.absolutePriorityTaskIds,
      timerByTaskId: host.timerElapsedByTaskId,
      pendingObsidianSyncTaskIds: host.pendingObsidianSyncTaskIds
    )
    // Animated as one transaction so the rows below rise to close the gap.
    // Nothing used to move after a completion: the celebration played, the
    // subtree went, and the rest of the list jumped up on the next frame — so
    // the last thing the user saw was a cut. This costs the inline budget
    // nothing, because by here the close request is already on its way.
    host.withListSettleAnimation {
      repository.tasks.removeSubrange(removingRange)
      repository.removeTasksFromPriorityQueue(snapshot.removedTaskIds)
      // A fetch issued before this point answers with the task still open, so
      // hide it from any such response until a newer fetch confirms the close.
      repository.suppressLocallyCompletedTasks(snapshot.removedTaskIds)
      host.clampSelectionToVisibleRange()
    }
    return snapshot
  }

  private func restoreTasksSnapshot(_ snapshot: OptimisticCompletionSnapshot) {
    guard let host else { return }
    reinsertRemovedTasks(snapshot)
    // The task is open after all, so stop filtering it out of fetch responses.
    repository.unsuppressLocallyCompletedTasks(snapshot.removedTaskIds)
    repository.savePriorityQueue(snapshot.priorityTaskIdsByParentId)
    repository.saveAbsolutePriorityQueue(snapshot.absolutePriorityTaskIds)
    host.timerElapsedByTaskId = snapshot.timerByTaskId
    host.savePendingObsidianSyncQueue(
      snapshot.pendingObsidianSyncTaskIds, listId: repository.listId)
    host.clampSelectionToVisibleRange()
  }

  /// Puts an optimistically-removed subtree back in place.
  ///
  /// Deliberately *not* a wholesale `tasks = snapshot` assignment: the request
  /// that failed was in flight across a suspension, and anything that landed
  /// meanwhile — a refetch, a sibling's completion — would be reverted with it.
  /// Same reasoning as `restoreTask`, one level up. Rows that came back on
  /// their own are left alone rather than duplicated.
  private func reinsertRemovedTasks(_ snapshot: OptimisticCompletionSnapshot) {
    let presentTaskIds = Set(repository.tasks.map(\.id))
    let block = snapshot.removedTasks.filter { !presentTaskIds.contains($0.id) }
    guard !block.isEmpty else { return }

    let insertIndex: Int
    switch snapshot.precedingTaskId {
    case nil:
      insertIndex = 0
    case let precedingTaskId?:
      insertIndex =
        repository.tasks.firstIndex(where: { $0.id == precedingTaskId }).map { $0 + 1 }
        ?? repository.tasks.endIndex
    }
    repository.tasks.insert(contentsOf: block, at: insertIndex)
  }

  private func nextOptimisticTaskId() -> Int {
    OptimisticTaskID.make()
  }

  // MARK: - Ancestor Helpers

  private func ancestorTaskIDs(for task: CheckvistTask, in taskList: [CheckvistTask]) -> [Int] {
    var taskByID: [Int: CheckvistTask] = [:]
    for listedTask in taskList {
      taskByID[listedTask.id] = listedTask
    }

    var ancestorIDs: [Int] = []
    var nextParentID = task.parentId ?? 0
    while nextParentID != 0 {
      ancestorIDs.append(nextParentID)
      guard let parent = taskByID[nextParentID] else { break }
      nextParentID = parent.parentId ?? 0
    }

    return ancestorIDs
  }

  /// Sends `.reopen` for each ancestor unconditionally to defeat Checkvist's
  /// auto-complete-parent cascade. Reopen is idempotent on already-open tasks,
  /// and sending it before the next fetch eliminates the race where a still-
  /// pending cascade closes an ancestor between fetches.
  private func reopenAncestorTasks(_ ancestorTaskIDs: [Int]) async {
    guard !ancestorTaskIDs.isEmpty else { return }
    for ancestorID in ancestorTaskIDs {
      do {
        _ = try await repository.activeSyncPlugin.performTaskAction(
          listId: repository.listId,
          taskId: ancestorID,
          action: .reopen,
          credentials: repository.activeCredentials
        )
      } catch CheckvistSessionError.authenticationUnavailable {
        repository.setAuthenticationRequiredErrorIfNeeded()
        return
      } catch {
        if repository.errorMessage == nil {
          repository.errorMessage = "Task completed, but a parent task could not be kept open."
        }
      }
    }
  }

  // MARK: - Priority mutations on the current task

  @MainActor func setPriorityForCurrentTask(_ rank: Int) {
    guard rank >= 1, let host, let task = host.currentTask else { return }

    let scopeId = task.parentId ?? 0
    var byParent = removingTaskFromAllPriorityScopes(
      task.id, in: repository.priorityTaskIdsByParentId)
    var scope = byParent[scopeId] ?? []
    let insertIndex = min(max(rank - 1, 0), scope.count)
    scope.insert(task.id, at: insertIndex)
    byParent[scopeId] = scope
    repository.savePriorityQueue(byParent)
    repository.errorMessage = nil

    reselect(taskId: task.id, on: host)
  }

  @MainActor func setAbsolutePriorityForCurrentTask(_ rank: Int) {
    guard rank >= 1, let host, let task = host.currentTask else { return }
    repository.setAbsolutePriority(taskId: task.id, rank: rank)
    repository.errorMessage = nil

    reselect(taskId: task.id, on: host)
  }

  @MainActor func sendCurrentTaskToPriorityBack() {
    guard let host, let task = host.currentTask else { return }

    let scopeId = task.parentId ?? 0
    var byParent = removingTaskFromAllPriorityScopes(
      task.id, in: repository.priorityTaskIdsByParentId)
    var scope = byParent[scopeId] ?? []
    scope.append(task.id)
    byParent[scopeId] = scope
    repository.savePriorityQueue(byParent)
    repository.errorMessage = nil

    reselect(taskId: task.id, on: host)
  }

  @MainActor func clearPriorityForCurrentTask() {
    guard let host, let task = host.currentTask else { return }
    guard repository.prioritizedTaskIds.contains(task.id) else { return }
    repository.savePriorityQueue(
      removingTaskFromAllPriorityScopes(task.id, in: repository.priorityTaskIdsByParentId))
    repository.errorMessage = nil

    reselectOrClamp(taskId: task.id, on: host)
  }

  @MainActor func clearAbsolutePriorityForCurrentTask() {
    guard let host, let task = host.currentTask else { return }
    guard repository.absolutePrioritizedTaskIds.contains(task.id) else { return }
    repository.clearAbsolutePriority(taskId: task.id)
    repository.errorMessage = nil

    reselectOrClamp(taskId: task.id, on: host)
  }

  /// Strips `taskId` from every per-parent priority queue, dropping scopes that
  /// end up empty. A task ranks in at most one scope, but stale entries from an
  /// earlier parent would otherwise survive a re-rank.
  private func removingTaskFromAllPriorityScopes(
    _ taskId: Int, in byParent: [Int: [Int]]
  ) -> [Int: [Int]] {
    var result = byParent
    for (parentId, ids) in byParent {
      let filtered = ids.filter { $0 != taskId }
      guard filtered.count != ids.count else { continue }
      if filtered.isEmpty {
        result.removeValue(forKey: parentId)
      } else {
        result[parentId] = filtered
      }
    }
    return result
  }

  /// Re-anchors the selection cursor on a task after a re-rank moved it.
  private func reselect(taskId: Int, on host: any TaskMutationHost) {
    if let newIndex = host.visibleTasks.firstIndex(where: { $0.id == taskId }) {
      host.currentSiblingIndex = newIndex
    }
  }

  /// Same as `reselect`, but for the clear-priority paths, where losing a rank
  /// can filter the task out of the priority view entirely.
  private func reselectOrClamp(taskId: Int, on host: any TaskMutationHost) {
    if let newIndex = host.visibleTasks.firstIndex(where: { $0.id == taskId }) {
      host.currentSiblingIndex = newIndex
    } else {
      host.clampSelectionToVisibleRange()
    }
  }
}
