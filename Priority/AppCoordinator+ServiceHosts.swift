import AppKit
import Foundation
import PriorityCore
import SwiftUI

/// `AppCoordinator`'s production conformance to the seams that
/// `TaskMutationService` and `SyncService` talk through.
///
/// This is deliberately the *only* app-only half of the split: everything here
/// is either a forward into a manager the coordinator already owns, or a piece
/// of genuinely UI-bound behaviour (haptics, the completion animation, the
/// kanban column maths, the recurrence rule store) that has no business in
/// `PriorityAppLogic`. The services themselves are now testable without it.

// MARK: - Shared

extension AppCoordinator: TaskServiceHost {
  var visibleTasks: [CheckvistTask] { taskListViewModel.visibleTasks }

  var currentSiblingIndex: Int {
    get { navigationState.currentSiblingIndex }
    set { navigationState.currentSiblingIndex = newValue }
  }

  func subtreeBlockRange(for taskId: Int, in tasks: [CheckvistTask]) -> Range<Int>? {
    taskListViewModel.subtreeBlockRange(for: taskId, in: tasks)
  }

  func reconcilePendingObsidianSyncQueue(openTaskIds: Set<Int>, listId: String) {
    integrations.reconcilePendingObsidianSyncQueueWithOpenTasks(
      openTaskIds: openTaskIds, listId: listId)
  }
}

// MARK: - TaskMutationHost

extension AppCoordinator: TaskMutationHost {
  var currentTask: CheckvistTask? { taskListViewModel.currentTask }

  var currentLevelTasks: [CheckvistTask] { taskListViewModel.currentLevelTasks }

  func isDescendant(_ task: CheckvistTask, of ancestorId: Int) -> Bool {
    taskListViewModel.isDescendant(task, of: ancestorId)
  }

  func clampSelectionToVisibleRange() {
    taskNavigationService.clampSelectionToVisibleRange()
  }

  var lastUndoableAction: UndoableAction? {
    get { undoService.lastAction }
    set { undoService.lastAction = newValue }
  }

  var kanbanSelectedTaskId: Int? {
    get { kanban.kanbanSelectedTaskId }
    set { kanban.kanbanSelectedTaskId = newValue }
  }

  func fetchTopTask() async {
    await syncService.fetchTopTask()
  }

  var timerElapsedByTaskId: [Int: TimeInterval] {
    get { timer.timerByTaskId }
    set { timer.timerByTaskId = newValue }
  }

  var pendingObsidianSyncTaskIds: [Int] { integrations.pendingObsidianSyncTaskIds }

  func savePendingObsidianSyncQueue(_ taskIds: [Int], listId: String) {
    integrations.savePendingObsidianSyncQueue(taskIds, listId: listId)
  }

  func presentOnboardingDialogIfNeeded() {
    onboardingService.presentOnboardingDialogIfNeeded()
  }

  // MARK: Quick Add

  var quickAddPrefersSpecificLocation: Bool {
    preferences.quickAddLocationMode == .specificParentTask
  }

  var quickAddSpecificParentTaskId: Int? {
    preferences.quickAddSpecificParentTaskIdValue
  }

  func setQuickAddSpecificParentTask(id: Int) {
    preferences.quickAddSpecificParentTaskId = String(id)
    preferences.quickAddLocationMode = .specificParentTask
  }

  func beginQuickAddEntry(useSpecificLocation: Bool) {
    quickEntry.pendingDeleteConfirmation = false
    quickEntry.commandSuggestionIndex = 0
    quickEntry.quickEntryMode = useSpecificLocation ? .quickAddSpecific : .quickAddDefault
    quickEntry.quickEntryText = ""
    quickEntry.isQuickEntryFocused = true
  }

  func finishQuickAddEntry() {
    quickEntry.quickEntryMode = .search
    quickEntry.quickEntryText = ""
    quickEntry.isQuickEntryFocused = false
  }

  // MARK: Recurrence

  func nextOccurrence(for completedTask: CheckvistTask)
    -> (dueDateString: String, savedRule: String)?
  {
    recurrence.computeNextOccurrence(
      for: completedTask,
      parseDueDateString: RecurrenceManager.parseDueDateString
    )
  }

  func hasRecurrenceRule(forTaskId taskId: Int) -> Bool {
    guard let raw = recurrence.recurrenceRulesByTaskId[taskId] else { return false }
    return !raw.isEmpty
  }

  func transferRecurrenceRule(fromTaskId: Int, toTaskId: Int, rule: String) {
    recurrence.transferRule(from: fromTaskId, to: toTaskId, rule: rule)
  }

  func clearRecurrenceRule(forTaskId taskId: Int) {
    recurrence.recurrenceRulesByTaskId.removeValue(forKey: taskId)
  }

  // MARK: Daily log

  func recordDayLogTaskAction(taskId: Int, title: String, action: CheckvistTaskAction) {
    switch action {
    case .close:
      dailyLog.recordCompletion(taskId: taskId, title: title)
    case .reopen:
      dailyLog.recordReopen(taskId: taskId, title: title)
    case .invalidate:
      dailyLog.recordInvalidation(taskId: taskId, title: title)
    }
  }

  // MARK: Completion feedback

  /// Runs the celebration for a task the user just closed, and returns `false`
  /// when it was cancelled — the user navigated away or switched tasks
  /// mid-animation — which tells the caller to abandon the mutation rather than
  /// send it late.
  ///
  /// Two things happen here that the celebration plugin does *not* control:
  ///
  /// - **The haptics.** They fire for every completion regardless of the chosen
  ///   preset, including "None". They are confirmation, not celebration; a user
  ///   who wants no animation should not thereby lose the tap that says the
  ///   keypress registered.
  /// - **The milestone classification.** The occasion is decided here, from
  ///   state only the coordinator can see, and handed to the preset as a fact.
  ///   Presets choose how to render an occasion, not which occasion it is.
  ///
  /// A milestone flourish is started but deliberately *not* awaited, so it
  /// overlaps the close request instead of delaying it. That is the whole
  /// reason the celebration is split in two — see
  /// `CompletionMilestonePolicy.inlineBudget`.
  func runTaskCompletionFeedback(taskId: Int) async -> Bool {
    // `.drawCompleted` rather than `.now`: it defers the tap until the frame
    // the row's first movement is actually on screen, so the two land together
    // instead of the haptic arriving a frame or two ahead of anything visible.
    // A tap that precedes its own animation reads as a stray click.
    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .drawCompleted)
    let event = completionEvent(for: .task(id: taskId), alreadyRecorded: false)

    guard await celebration.runInline(event) else { return false }

    NSHapticFeedbackManager.defaultPerformer.perform(
      .levelChange, performanceTime: .drawCompleted)
    celebration.presentFlourish(for: event)
    return true
  }

  func withListSettleAnimation(_ body: () -> Void) {
    withAnimation(CelebrationMotion.listSettle(reduceMotion: celebration.prefersReducedMotion)) {
      body()
    }
  }

  /// Classifies a completion against the day's log and the current list.
  ///
  /// `visibleTasks.count` is read *before* the optimistic removal, so the last
  /// task in the list reads as `1` — which is what
  /// `CompletionMilestonePolicy.milestone` expects.
  ///
  /// - Parameter alreadyRecorded: whether the day log already counts this
  ///   completion. False on the task path, which celebrates before sending the
  ///   close; true on the daily path, where the tick is local and lands first.
  func completionEvent(for kind: CompletionKind, alreadyRecorded: Bool) -> CompletionEvent {
    let ordinal = dailyLog.completedTodayCount() + (alreadyRecorded ? 0 : 1)
    // Days *before* today, plus the one being earned right now. The aggregator
    // excludes today deliberately: the task path classifies before its close is
    // recorded and the daily path after, so a streak that counted today would
    // come out a day apart depending on which funnel asked.
    let streakDays = dailyLog.priorCompletionStreak() + 1
    return CompletionEvent(
      kind: kind,
      milestone: CompletionMilestonePolicy.milestone(
        for: kind,
        remainingVisibleTaskCount: taskListViewModel.visibleTasks.count,
        ordinal: ordinal,
        streakDays: streakDays
      ),
      ordinal: ordinal
    )
  }
}

// MARK: - SyncHost

extension AppCoordinator: SyncHost {
  var taskMoveMode: TaskMoveMode {
    switch taskListViewModel.rootTaskView {
    case .priority: return .priorityQueue
    case .kanban: return .kanbanColumn
    case .due: return .dueDate
    case .all, .tags, .eisenhower, .daily: return .siblingPosition
    }
  }

  var currentParentId: Int {
    get { navigationState.currentParentId }
    set { navigationState.currentParentId = newValue }
  }

  var kanbanFilterParentId: Int? {
    get { kanban.kanbanFilterParentId }
    set { kanban.kanbanFilterParentId = newValue }
  }

  /// Purely visual reorder: writes only to the per-column manual-order overlay
  /// for whichever column currently hosts the task, never to its date,
  /// priority, or position.
  func moveTaskWithinKanbanColumn(taskId: Int, direction: Int) {
    let columns = kanban.kanbanColumns
    let hostingColumn = columns.first { column in
      kanban.tasksForKanbanColumn(column, allColumns: columns)
        .contains { $0.id == taskId }
    }
    guard let column = hostingColumn else { return }
    kanban.nudgeTaskInColumn(taskId: taskId, in: column, direction: direction)
  }

  func clampKanbanSelection() {
    kanban.clampKanbanSelection()
  }

  func clearKanbanSelection() {
    kanban.kanbanSelectedTaskId = nil
  }

  func clampFocusSessionForTasks(_ tasks: [CheckvistTask]) {
    focusSessionManager.clampForTasks(tasks)
  }

  func reconcileTimersAfterFetch(previousTasks: [CheckvistTask], openTasks: [CheckvistTask]) {
    let latestOpenTaskIDs = Set(openTasks.map(\.id))
    let previousTimerNodes = previousTasks.map {
      TimerNode(id: $0.id, parentId: $0.parentId)
    }
    timer.timerByTaskId = TimerElapsedReassignmentPolicy.remapElapsed(
      previousNodes: previousTimerNodes,
      latestOpenTaskIDs: latestOpenTaskIDs,
      elapsedByTaskID: timer.timerByTaskId
    )
    timer.stopTimerIfTaskRemoved(openTaskIds: latestOpenTaskIDs)
  }

  func markOnboardingCompleted() {
    onboardingService.onboardingCompleted = true
  }

  func applyOptimisticUpdate(task: CheckvistTask, content: String?, due: String?) {
    taskMutationService.applyOptimisticUpdate(task: task, content: content, due: due)
  }
}

// MARK: - TaskListViewModelHost

/// Five managers, all read-only from the view model's side. Each forwards to
/// the real `@Observable` object rather than caching a copy, so SwiftUI's
/// dependency tracking still registers on the underlying property.
/// `currentParentId`, `currentSiblingIndex` and `timerElapsedByTaskId` are
/// already provided above for the mutation and sync hosts — the same facts,
/// wanted by three different collaborators, which is the point of stating them
/// once on the coordinator.
extension AppCoordinator: TaskListViewModelHost {
  var isSearchFilterActive: Bool { quickEntry.isSearchFilterActive }
  var searchText: String { quickEntry.searchText }
  var showsTaskBreadcrumbContext: Bool { preferences.showTaskBreadcrumbContext }
  var kanbanCurrentTask: CheckvistTask? { kanban.currentKanbanTask }
  var matrixSelectedTaskId: Int? { navigationState.matrixSelectedTaskId }
}
