import XCTest

@testable import PriorityAppLogic

/// Coverage for the optimistic-mutation layer: what lands in `tasks`
/// immediately, what gets rolled back when the server says no, and what gets
/// queued instead when the network is gone.
@MainActor
final class TaskMutationServiceTests: XCTestCase {
  private var defaults: UserDefaults!
  private var preferencesStore: PreferencesStore!
  private var localTaskStore: LocalTaskStore!
  private var plugin: FakeCheckvistSyncPlugin!
  private var repository: TaskRepository!
  private var host: StubTaskServiceHost!
  private var service: TaskMutationService!

  override func setUp() async throws {
    try await super.setUp()
    defaults = makeIsolatedDefaultsSuite()
    preferencesStore = PreferencesStore(defaults: defaults)
    localTaskStore = LocalTaskStore(defaults: defaults)
    plugin = FakeCheckvistSyncPlugin()

    // Credentials + list + integration on, so `activeSyncPlugin` resolves to
    // the fake Checkvist plugin rather than the offline store.
    preferencesStore.set("tester", for: .checkvistUsername)
    preferencesStore.set("42", for: .checkvistListId)
    preferencesStore.set(true, for: .checkvistIntegrationEnabled)

    repository = TaskRepository(
      preferencesStore: preferencesStore,
      checkvistSyncPlugin: plugin,
      localTaskStore: localTaskStore,
      initialRemoteKey: "key",
      defaults: defaults
    )
    XCTAssertTrue(repository.canSyncRemotely, "tests assume the online routing branch")

    host = StubTaskServiceHost()
    host.repository = repository
    service = TaskMutationService(host: host, repository: repository)
  }

  // MARK: - Rollback after a suspension

  /// The rollback has to re-find the task by id. A captured index goes stale
  /// across the `await`, because other main-actor work (a refetch, a sibling
  /// completion) can reshape `tasks` while the update is in flight — and the
  /// old code then wrote the original task over whatever now sat at that index.
  func testUpdateRollbackRestoresTheRightTaskAfterTheListShiftedUnderIt() async {
    repository.tasks = [
      makeTask(id: 1, content: "alpha"),
      makeTask(id: 2, content: "bravo"),
      makeTask(id: 3, content: "charlie"),
    ]
    let target = repository.tasks[1]

    // Simulate a refetch landing mid-flight: the row ahead of the target goes
    // away, so the target's index shifts from 1 to 0.
    plugin.beforeUpdateTaskReturns = { [weak self] in
      self?.repository.tasks.removeAll { $0.id == 1 }
    }
    plugin.updateTaskError = CheckvistSessionError.requestFailed

    await service.updateTask(task: target, content: "edited")

    XCTAssertEqual(repository.tasks.map(\.id), [2, 3])
    XCTAssertEqual(repository.tasks[0].content, "bravo", "target should be rolled back")
    XCTAssertEqual(repository.tasks[1].content, "charlie", "bystander must be untouched")
  }

  func testUpdateAppliesOptimisticallyAndKeepsItOnSuccess() async {
    repository.tasks = [makeTask(id: 1, content: "alpha")]

    await service.updateTask(task: repository.tasks[0], content: "edited")

    XCTAssertEqual(repository.tasks[0].content, "edited")
    XCTAssertEqual(host.fetchTopTaskCallCount, 1)
    XCTAssertNil(repository.errorMessage)
  }

  func testUpdateWhileOfflineKeepsTheEditAndQueuesItForReplay() async {
    repository.tasks = [makeTask(id: 1, content: "alpha")]
    repository.isNetworkReachable = false
    plugin.updateTaskError = CheckvistSessionError.requestFailed

    await service.updateTask(task: repository.tasks[0], due: "2026-09-01")

    XCTAssertEqual(repository.tasks[0].due, "2026-09-01", "optimistic edit must survive")
    XCTAssertEqual(repository.pendingTaskMutations[1]?.due, "2026-09-01")
    XCTAssertEqual(repository.errorMessage, "Offline — will sync when connected.")
  }

  // MARK: - Add

  func testAddOnlineFailureRemovesTheOptimisticTask() async {
    repository.tasks = [makeTask(id: 1, content: "alpha")]
    plugin.createTaskError = CheckvistSessionError.requestFailed

    await service.addTask(content: "new thing")

    XCTAssertEqual(repository.tasks.map(\.id), [1])
    XCTAssertTrue(repository.pendingTaskCreates.isEmpty)
    XCTAssertEqual(repository.errorMessage?.hasPrefix("Error adding task:"), true)
  }

  func testAddWhileOfflineKeepsTheOptimisticTaskAndQueuesTheCreate() async throws {
    repository.tasks = [makeTask(id: 1, content: "alpha")]
    repository.isNetworkReachable = false
    plugin.createTaskError = CheckvistSessionError.requestFailed

    await service.addTask(content: "new thing")

    XCTAssertEqual(repository.tasks.count, 2)
    let optimistic = try XCTUnwrap(repository.tasks.first { $0.id != 1 })
    XCTAssertEqual(optimistic.content, "new thing")
    XCTAssertLessThan(optimistic.id, 0, "placeholder ids are negative")
    XCTAssertEqual(repository.pendingTaskCreates.count, 1)
    XCTAssertEqual(repository.pendingTaskCreates.first?.tempId, optimistic.id)
  }

  /// The list is an outline, so the selected row can be nested well inside the
  /// scope while `currentParentId` still names the scope. Adding a sibling has
  /// to follow the row, not the scope — taking the parent from the scope put
  /// every add under a nested row back at the top level.
  func testAddingASiblingOfANestedRowKeepsItUnderThatRowsParent() async {
    repository.tasks = [
      makeTask(id: 1, content: "parent", position: 1),
      makeTask(id: 2, content: "child", parentId: 1, position: 1),
    ]
    host.currentParentId = 0
    host.currentTask = repository.tasks[1]

    await service.addTask(content: "new sibling")

    XCTAssertEqual(plugin.createTaskCalls.first?.parentId, 1)
    XCTAssertEqual(plugin.createTaskCalls.first?.position, 2)
    XCTAssertEqual(
      repository.tasks.first(where: { $0.content == "new sibling" })?.parentId, 1,
      "the optimistic row has to agree with the create"
    )
  }

  /// Add-to-top is the one add that really does mean the current level, so it
  /// keeps reading the scope even when a nested row is selected.
  func testAddingAtTheTopOfTheLevelStillUsesTheScopeRatherThanTheSelectedRow() async {
    repository.tasks = [
      makeTask(id: 1, content: "parent", position: 1),
      makeTask(id: 2, content: "child", parentId: 1, position: 1),
    ]
    host.currentParentId = 0
    host.currentTask = repository.tasks[1]

    await service.addTask(content: "new top", insertAtTopOfCurrentLevel: true)

    XCTAssertNil(plugin.createTaskCalls.first?.parentId)
    XCTAssertEqual(plugin.createTaskCalls.first?.position, 1)
  }

  func testAddWithoutAListPromptsSetupInsteadOfCallingTheServer() async {
    repository.listId = ""

    await service.addTask(content: "new thing")

    XCTAssertEqual(repository.errorMessage, "Choose a Checkvist list in Preferences to add tasks.")
    XCTAssertTrue(plugin.createTaskCalls.isEmpty)
  }

  // MARK: - Mark done

  func testMarkDoneRemovesTheWholeSubtreeOptimisticallyAndClosesTheTask() async {
    repository.tasks = [
      makeTask(id: 1, content: "parent"),
      makeTask(id: 2, content: "child", parentId: 1),
      makeTask(id: 3, content: "unrelated"),
    ]
    host.currentTask = repository.tasks[0]

    await service.markCurrentTaskDone()

    XCTAssertEqual(repository.tasks.map(\.id), [3], "parent and child both leave the list")
    XCTAssertEqual(plugin.performTaskActionCalls.count, 1)
    XCTAssertEqual(plugin.performTaskActionCalls.first?.taskId, 1)
    XCTAssertEqual(plugin.performTaskActionCalls.first?.action, .close)
  }

  /// The haptic/animation sequence is the host's job, and it can be cancelled
  /// by the user navigating away. A cancelled sequence must abort the close
  /// rather than let it fire late against a task the user has moved off.
  func testMarkDoneIsAbandonedWhenTheCompletionFeedbackIsCancelled() async {
    repository.tasks = [makeTask(id: 1, content: "parent")]
    host.currentTask = repository.tasks[0]
    host.completionFeedbackSucceeds = false

    await service.markCurrentTaskDone()

    XCTAssertEqual(host.completionFeedbackTaskIds, [1])
    XCTAssertTrue(plugin.performTaskActionCalls.isEmpty)
    XCTAssertEqual(repository.tasks.map(\.id), [1], "the task stays put")
  }

  /// The removal has to happen inside the host's transaction, not beside it.
  /// Outside it the rows below snap up on the next frame — which is what the
  /// list used to do, and the reason a completion ended on a cut rather than on
  /// the list closing over the gap.
  func testTheOptimisticRemovalRunsInsideTheListSettleTransaction() async {
    repository.tasks = [
      makeTask(id: 1, content: "parent"),
      makeTask(id: 2, content: "unrelated"),
    ]
    host.currentTask = repository.tasks[0]

    await service.markCurrentTaskDone()

    XCTAssertEqual(host.listSettleAnimationCallCount, 1)
    XCTAssertEqual(repository.tasks.map(\.id), [2], "and the body actually ran")
  }

  func testTaskActionRestoresTheSubtreeWhenTheServerRejectsTheClose() async {
    repository.tasks = [
      makeTask(id: 1, content: "parent"),
      makeTask(id: 2, content: "child", parentId: 1),
    ]
    plugin.performTaskActionResult = false

    await service.taskAction(repository.tasks[0], endpoint: "close")

    XCTAssertEqual(repository.tasks.map(\.id), [1, 2])
    XCTAssertEqual(repository.errorMessage, "Failed to close task.")
  }

  /// Mark-done spends the completion animation with the row still selected, so
  /// a second press of the key lands before the close has even gone out. It used
  /// to fire a second close: two day-log entries for one completion, and two
  /// next occurrences for a recurring task.
  func testASecondMarkDoneInsideTheFeedbackWindowIsIgnored() async {
    repository.tasks = [makeTask(id: 1, content: "water plants")]
    host.currentTask = repository.tasks[0]
    host.recurrenceRules = [1: "every day"]
    host.nextOccurrenceDueDateString = "2026-08-18"
    host.duringCompletionFeedback = { [weak self] in
      guard let self else { return }
      self.host.duringCompletionFeedback = nil
      await self.service.markCurrentTaskDone()
    }

    await service.markCurrentTaskDone()

    XCTAssertEqual(host.completionFeedbackTaskIds, [1], "no second animation")
    XCTAssertEqual(
      plugin.performTaskActionCalls.filter { $0.action == .close }.count, 1,
      "the task is closed once")
    XCTAssertEqual(host.dayLogTaskActions.count, 1, "one entry in the day log")
    XCTAssertEqual(plugin.createTaskCalls.count, 1, "one next occurrence, not two")
  }

  /// The rollback used to assign the whole pre-removal array back over `tasks`,
  /// which also reverted anything that had landed while the close was in flight.
  func testCloseRollbackReinsertsTheSubtreeWithoutRevertingWhatLandedMeanwhile() async {
    repository.tasks = [
      makeTask(id: 1, content: "parent"),
      makeTask(id: 2, content: "child", parentId: 1),
      makeTask(id: 3, content: "unrelated"),
    ]
    plugin.performTaskActionResult = false
    plugin.beforePerformTaskActionReturns = { [weak self] in
      self?.repository.tasks.append(makeTask(id: 4, content: "arrived mid-flight"))
    }

    await service.taskAction(repository.tasks[0], endpoint: "close")

    XCTAssertEqual(
      repository.tasks.map(\.id), [1, 2, 3, 4],
      "the subtree goes back in place and the new arrival survives")
  }

  /// Rolling a close back means the task is open after all, so the filter that
  /// keeps an in-flight fetch from resurrecting it has to be lifted too — or the
  /// task stays invisible until the app is relaunched.
  func testARolledBackCloseStopsHidingTheTaskFromLaterFetches() async {
    repository.tasks = [makeTask(id: 1, content: "alpha")]
    plugin.openTasksByListId["42"] = [makeTask(id: 1, content: "alpha")]
    plugin.performTaskActionResult = false
    let syncService = SyncService(host: host, repository: repository)

    await service.taskAction(repository.tasks[0], endpoint: "close")
    await syncService.fetchTopTask()

    XCTAssertEqual(repository.tasks.map(\.id), [1])
  }

  /// Undo of a mark-done reopens a task the fetch filter is still hiding. Same
  /// requirement as the rollback above, reached through the undo path.
  func testUndoingACloseLetsTheTaskComeBackOnTheNextFetch() async {
    repository.tasks = [makeTask(id: 1, content: "alpha")]
    plugin.openTasksByListId["42"] = [makeTask(id: 1, content: "alpha")]
    let syncService = SyncService(host: host, repository: repository)

    await service.taskAction(repository.tasks[0], endpoint: "close")
    XCTAssertTrue(repository.tasks.isEmpty, "closed optimistically")

    await service.taskAction(
      makeTask(id: 1, content: "", status: 1), endpoint: "reopen", isUndo: true)
    await syncService.fetchTopTask()

    XCTAssertEqual(repository.tasks.map(\.id), [1])
  }

  func testCloseWhileOfflineQueuesTheActionAndAnAncestorReopen() async {
    repository.tasks = [
      makeTask(id: 1, content: "parent"),
      makeTask(id: 2, content: "child", parentId: 1),
    ]
    repository.isNetworkReachable = false
    plugin.performTaskActionError = CheckvistSessionError.requestFailed

    await service.taskAction(repository.tasks[1], endpoint: "close")

    XCTAssertEqual(
      repository.pendingTaskActions.map(\.taskId), [2, 1],
      "the close, then the ancestor reopen that defeats Checkvist's cascade")
    XCTAssertEqual(repository.pendingTaskActions.map(\.action), [.close, .reopen])
  }

  // MARK: - Delete

  func testDeletingAStillQueuedOfflineCreateCancelsItInsteadOfCallingTheServer() async {
    let tempId = -7
    repository.tasks = [makeTask(id: tempId, content: "offline task")]
    repository.enqueuePendingCreate(
      PendingTaskCreate(tempId: tempId, content: "offline task", parentId: nil, position: 1))

    await service.deleteTask(repository.tasks[0])

    XCTAssertTrue(repository.pendingTaskCreates.isEmpty)
    XCTAssertTrue(repository.tasks.isEmpty)
    XCTAssertTrue(plugin.deleteTaskCalls.isEmpty, "never round-trip a create+delete")
  }

  func testDeleteRemovesTheSubtreeImmediatelyAndCallsTheServer() async {
    repository.tasks = [
      makeTask(id: 1, content: "parent"),
      makeTask(id: 2, content: "child", parentId: 1),
      makeTask(id: 3, content: "unrelated"),
    ]

    await service.deleteTask(repository.tasks[0])
    await settle()

    XCTAssertEqual(repository.tasks.map(\.id), [3])
    XCTAssertEqual(plugin.deleteTaskCalls, [1])
    XCTAssertEqual(host.obsidianReconcileCalls.count, 1)
  }

  func testDeleteRestoresTheSubtreeWhenTheServerRejectsIt() async {
    repository.tasks = [
      makeTask(id: 1, content: "parent"),
      makeTask(id: 2, content: "child", parentId: 1),
    ]
    plugin.deleteTaskResult = false

    await service.deleteTask(repository.tasks[0])
    await settle()

    XCTAssertEqual(repository.tasks.map(\.id), [1, 2])
    XCTAssertEqual(repository.errorMessage, "Failed to delete task.")
  }

  // MARK: - Recurrence

  /// Two open siblings share a title; only one of them is the occurrence we
  /// just created. Matching on content alone moved the recurrence rule onto
  /// whichever came first, so the series silently jumped to the wrong task.
  func testNextOccurrenceTransfersTheRuleToTheNewTaskNotASameTitledSibling() async throws {
    repository.tasks = [
      makeTask(id: 1, content: "water plants"),
      makeTask(id: 2, content: "water plants"),
    ]
    let completed = repository.tasks[0]
    host.recurrenceRules = [1: "every day"]
    host.nextOccurrenceDueDateString = "2026-08-14"

    await service.createNextOccurrence(for: completed)

    let newTask = try XCTUnwrap(
      repository.tasks.first { $0.id != 1 && $0.id != 2 },
      "a next occurrence should have been inserted")
    XCTAssertEqual(host.recurrenceRules[newTask.id], "every day")
    XCTAssertNil(host.recurrenceRules[1], "the completed task gives up its rule")
    XCTAssertNil(host.recurrenceRules[2], "the same-titled sibling must not inherit it")
  }

  func testNoRecurrenceRuleMeansNoNextOccurrenceAndNoErrorNoise() async {
    repository.tasks = [makeTask(id: 1, content: "one-off")]

    await service.createNextOccurrence(for: repository.tasks[0])

    XCTAssertEqual(repository.tasks.map(\.id), [1])
    XCTAssertNil(repository.errorMessage)
  }

  func testUncomputableNextOccurrenceReportsTheFailureForARecurringTask() async {
    repository.tasks = [makeTask(id: 1, content: "recurring")]
    host.recurrenceRules = [1: "gibberish"]
    host.nextOccurrenceDueDateString = nil

    await service.createNextOccurrence(for: repository.tasks[0])

    XCTAssertEqual(
      repository.errorMessage, "Could not calculate next occurrence for recurring task.")
  }

  // MARK: - Quick Add

  func testQuickAddRefusesSpecificModeUntilAParentTaskIsConfigured() {
    host.quickAddSpecificParentTaskId = nil

    XCTAssertFalse(service.beginQuickAddEntry(preferSpecificLocation: true))
    XCTAssertTrue(host.beginQuickAddCalls.isEmpty, "focus must be left alone")
    XCTAssertEqual(
      repository.errorMessage, "Set a valid Quick Add parent task ID in Preferences first.")
  }

  func testQuickAddFollowsTheConfiguredLocationModeWhenNotOverridden() {
    host.quickAddPrefersSpecificLocation = true
    host.quickAddSpecificParentTaskId = 99

    XCTAssertTrue(service.beginQuickAddEntry())
    XCTAssertEqual(host.beginQuickAddCalls, [true])
  }

  func testQuickAddSubmitCreatesUnderTheSpecificParentAndClosesTheEntryBar() async {
    host.quickAddSpecificParentTaskId = 99

    await service.submitQuickAddTask(content: "  inbox item  ", useSpecificLocation: true)

    XCTAssertEqual(plugin.createTaskCalls.count, 1)
    XCTAssertEqual(plugin.createTaskCalls.first?.content, "inbox item")
    XCTAssertEqual(plugin.createTaskCalls.first?.parentId, 99)
    XCTAssertEqual(host.finishQuickAddCallCount, 1)
  }

  /// Offline quick add has no refetch to surface the new task, so it has to
  /// insert the placeholder itself — otherwise the task the user just typed
  /// vanishes until the next reconnect.
  func testQuickAddWhileOfflineInsertsAPlaceholderAndQueuesTheCreate() async {
    repository.isNetworkReachable = false
    plugin.createTaskError = CheckvistSessionError.requestFailed

    await service.submitQuickAddTask(content: "inbox item", useSpecificLocation: false)

    XCTAssertEqual(repository.tasks.count, 1)
    XCTAssertEqual(repository.tasks.first?.content, "inbox item")
    XCTAssertEqual(repository.pendingTaskCreates.count, 1)
    XCTAssertEqual(host.finishQuickAddCallCount, 1)
  }

  // MARK: - Board mutations
  //
  // These two arrived from `AppCoordinator`, where they were untestable and had
  // quietly drifted from the shared failure handling. That drift is what the
  // offline cases below pin down.

  func testAnOptimisticUpdateLandsLocallyBeforeTheServerIsAsked() {
    let task = makeTask(id: 1, content: "todo", due: "today")
    repository.tasks = [task]

    service.applyOptimisticUpdate(task: task, content: "doing", due: "tomorrow")

    XCTAssertEqual(repository.tasks.first?.content, "doing")
    XCTAssertEqual(repository.tasks.first?.due, "tomorrow")
    guard case .update(let undoId, let oldContent, let oldDue) = host.lastUndoableAction else {
      return XCTFail("expected an update to be undoable")
    }
    XCTAssertEqual(undoId, 1)
    XCTAssertEqual(oldContent, "todo")
    XCTAssertEqual(oldDue, "today")
  }

  /// The bug this method was moved to fix: the coordinator's copy wrote
  /// `pendingTaskMutations` directly, so the edit lived in memory only and was
  /// gone at the next launch.
  func testAnOptimisticUpdateThatFailsOfflineIsQueuedToDisk() async {
    let task = makeTask(id: 1, content: "todo", due: "today")
    repository.tasks = [task]
    repository.isNetworkReachable = false
    plugin.updateTaskError = CheckvistSessionError.requestFailed

    await service.applyOptimisticUpdate(task: task, content: "doing", due: "tomorrow")?.value

    XCTAssertEqual(repository.tasks.first?.content, "doing", "optimistic state survives")
    XCTAssertEqual(repository.pendingTaskMutations[1]?.due, "tomorrow")
    XCTAssertEqual(
      repository.pendingOfflineWorkStore.load().mutations[1]?.due, "tomorrow",
      "and it reaches disk, which is the whole point of the queue")
  }

  func testAnOptimisticUpdateThatFailsOnlineRollsBack() async {
    let task = makeTask(id: 1, content: "todo", due: "today")
    repository.tasks = [task]
    plugin.updateTaskError = CheckvistSessionError.requestFailed

    await service.applyOptimisticUpdate(task: task, content: "doing", due: "tomorrow")?.value

    XCTAssertEqual(repository.tasks.first?.content, "todo")
    XCTAssertEqual(repository.tasks.first?.due, "today")
    XCTAssertNotNil(repository.errorMessage)
    XCTAssertTrue(repository.pendingTaskMutations.isEmpty)
  }

  func testAddingARootTaskClaimsTheKanbanSelectionThenHandsItToTheRealId() async {
    plugin.nextCreatedTaskId = 500

    let work = service.addRootTask(content: "new card", due: "today")
    XCTAssertEqual(repository.tasks.count, 1)
    let optimisticId = try? XCTUnwrap(repository.tasks.first?.id)
    XCTAssertEqual(host.kanbanSelectedTaskId, optimisticId)
    XCTAssertLessThan(optimisticId ?? 0, 0, "placeholder ids are negative")

    await work?.value

    XCTAssertEqual(repository.tasks.map(\.id), [500])
    XCTAssertEqual(host.kanbanSelectedTaskId, 500)
    XCTAssertEqual(repository.tasks.first?.due, "today")
    guard case .add(let undoId) = host.lastUndoableAction else {
      return XCTFail("expected the add to be undoable")
    }
    XCTAssertEqual(undoId, 500)
  }

  /// The coordinator's copy had no offline branch at all — a card added while
  /// disconnected was removed again the moment the request failed.
  func testARootTaskAddedOfflineIsQueuedRatherThanDiscarded() async {
    repository.isNetworkReachable = false
    plugin.createTaskError = CheckvistSessionError.requestFailed

    await service.addRootTask(content: "new card", due: "today")?.value

    XCTAssertEqual(repository.tasks.count, 1, "the card stays on the board")
    let tempId = try? XCTUnwrap(repository.tasks.first?.id)
    XCTAssertEqual(repository.pendingTaskCreates.map(\.content), ["new card"])
    XCTAssertEqual(
      repository.pendingTaskMutations[tempId ?? 0]?.due, "today",
      "the due date is queued separately — create does not carry one")

    let persisted = repository.pendingOfflineWorkStore.load()
    XCTAssertEqual(persisted.creates.map(\.content), ["new card"])
  }

  func testAddingARootTaskWithoutAListFailsLoudlyAndAddsNothing() {
    repository.listId = ""

    service.addRootTask(content: "new card", due: nil)

    XCTAssertTrue(repository.tasks.isEmpty)
    XCTAssertNotNil(repository.errorMessage)
  }

  // MARK: - Helpers

  /// Lets the unstructured `Task` that `deleteTask` spawns run to completion.
  private func settle() async {
    for _ in 0..<10 {
      await Task.yield()
    }
  }
}
