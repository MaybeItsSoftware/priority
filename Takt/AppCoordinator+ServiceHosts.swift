import AppKit
import Foundation
import TaktCore
import SwiftUI

// `AppCoordinator`'s production conformance to the seams that
// `TaskMutationService` and `SyncService` talk through.
//
// This is deliberately the *only* app-only half of the split: everything here
// is either a forward into a manager the coordinator already owns, or a piece
// of genuinely UI-bound behaviour (haptics, the completion animation, the
// recurrence rule store) that has no business in
// `TaktAppLogic`. The services themselves are now testable without it.
//
// The Checkvist cursor is answered here too. It used to be the legacy task
// list view model's: the row at `currentSiblingIndex` of whatever tab the
// popover was showing. The popover, its tabs and that view model are gone,
// and nothing on screen shows the cursor any more, but the sync and mutation
// services still select into it after a fetch, an insert or a removal. So it
// is now the open tasks at `currentParentId`, in list order (see
// `TaskFilterEngine.cursorLevel`) — stable and in range, which is all those
// paths need of it.

// MARK: - Shared

extension AppCoordinator: TaskServiceHost {
  var visibleTasks: [CheckvistTask] {
    TaskFilterEngine.cursorLevel(repository.tasks, parentId: navigationState.currentParentId)
  }

  var currentSiblingIndex: Int {
    get { navigationState.currentSiblingIndex }
    set { navigationState.currentSiblingIndex = newValue }
  }

  func subtreeBlockRange(for taskId: Int, in tasks: [CheckvistTask]) -> Range<Int>? {
    TaskFilterEngine.subtreeBlockRange(for: taskId, in: tasks)
  }

  func reconcilePendingObsidianSyncQueue(openTaskIds: Set<Int>, listId: String) {
    integrations.reconcilePendingObsidianSyncQueueWithOpenTasks(
      openTaskIds: openTaskIds, listId: listId)
  }
}

// MARK: - TaskMutationHost

extension AppCoordinator: TaskMutationHost {
  var currentTask: CheckvistTask? {
    TaskFilterEngine.cursorTask(in: visibleTasks, index: navigationState.currentSiblingIndex)
  }

  func isDescendant(_ task: CheckvistTask, of ancestorId: Int) -> Bool {
    let taskById = Dictionary(
      repository.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return TaskFilterEngine.isDescendant(task, of: ancestorId, taskById: taskById)
  }

  func clampSelectionToVisibleRange() {
    focusSessionManager.clampForTasks(repository.tasks)
    let maxIndex = max(visibleTasks.count - 1, 0)
    if navigationState.currentSiblingIndex > maxIndex {
      navigationState.currentSiblingIndex = maxIndex
    }
  }

  var lastUndoableAction: UndoableAction? {
    get { undoService.lastAction }
    set { undoService.lastAction = newValue }
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

  // MARK: Quick Add

  func beginQuickAddEntry() {
    quickEntry.pendingDeleteConfirmation = false
    quickEntry.commandSuggestionIndex = 0
    quickEntry.quickEntryMode = .quickAddDefault
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
        remainingVisibleTaskCount: visibleTasks.count,
        ordinal: ordinal,
        streakDays: streakDays
      ),
      ordinal: ordinal
    )
  }
}

// MARK: - SyncHost

extension AppCoordinator: SyncHost {
  /// Read from the root view the popover last persisted, as it always was:
  /// the tabs are gone but the preference is not, and a Checkvist move should
  /// not change strategy because the surface that set it was removed.
  var taskMoveMode: TaskMoveMode {
    let stored = RootTaskView(
      rawValue: preferences.preferencesStore.int(.rootTaskView, default: RootTaskView.due.rawValue))
    switch stored ?? .due {
    case .priority: return .priorityQueue
    case .due: return .dueDate
    case .all, .tags, .kanban, .eisenhower, .daily: return .siblingPosition
    }
  }

  var currentParentId: Int {
    get { navigationState.currentParentId }
    set { navigationState.currentParentId = newValue }
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
