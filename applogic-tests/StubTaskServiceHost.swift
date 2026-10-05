import Foundation

@testable import TaktAppLogic

/// Stands in for `AppCoordinator` when exercising `TaskMutationService` and
/// `SyncService`.
///
/// The tree-shape helpers (`subtreeBlockRange`, `isDescendant`,
/// `visibleTasks`) are real implementations over the repository's task
/// array rather than canned answers, because the optimistic-completion and
/// rollback paths under test are exactly the ones that depend on them being
/// right. Everything else records calls.
@MainActor
final class StubTaskServiceHost: TaskMutationHost, SyncHost {
  /// Weak to mirror production ownership and keep the test's repository the
  /// single source of truth for tasks.
  weak var repository: TaskRepository?

  // MARK: Recorded calls

  private(set) var fetchTopTaskCallCount = 0
  private(set) var clampSelectionCallCount = 0
  private(set) var beginQuickAddCallCount = 0
  private(set) var finishQuickAddCallCount = 0
  private(set) var obsidianReconcileCalls: [(openTaskIds: Set<Int>, listId: String)] = []
  private(set) var kanbanNudges: [(taskId: Int, direction: Int)] = []
  private(set) var clampKanbanSelectionCallCount = 0
  private(set) var clearKanbanSelectionCallCount = 0
  private(set) var focusClampCallCount = 0
  private(set) var timerReconcileCallCount = 0
  private(set) var onboardingCompletedCallCount = 0
  private(set) var optimisticMoveCalls: [(taskId: Int, content: String?, due: String?)] = []
  private(set) var completionFeedbackTaskIds: [Int] = []

  // MARK: Programmable behaviour

  /// What `runTaskCompletionFeedback` reports. `false` simulates the user
  /// navigating away mid-animation, which must abort the close.
  var completionFeedbackSucceeds = true
  /// Runs when the service asks for a refetch, so a test can simulate the
  /// server's view of the list replacing the optimistic one.
  var onFetchTopTask: (() -> Void)?
  /// Runs inside `runTaskCompletionFeedback` — the window where production is
  /// mid-animation and the close has not gone out yet, which is where a second
  /// press of the mark-done key lands.
  var duringCompletionFeedback: (@MainActor () async -> Void)?
  /// Recurrence rules keyed by task id, mirroring `RecurrenceManager`.
  var recurrenceRules: [Int: String] = [:]
  /// The due date `nextOccurrence` should hand back for a task that has a rule.
  var nextOccurrenceDueDateString: String?

  // MARK: TaskServiceHost

  private var tasks: [CheckvistTask] { repository?.tasks ?? [] }

  var visibleTasks: [CheckvistTask] { tasks }

  var currentSiblingIndex: Int = 0

  func subtreeBlockRange(for taskId: Int, in tasks: [CheckvistTask]) -> Range<Int>? {
    guard let start = tasks.firstIndex(where: { $0.id == taskId }) else { return nil }
    var end = start + 1
    while end < tasks.count && isDescendant(tasks[end], of: taskId, in: tasks) {
      end += 1
    }
    return start..<end
  }

  func reconcilePendingObsidianSyncQueue(openTaskIds: Set<Int>, listId: String) {
    obsidianReconcileCalls.append((openTaskIds, listId))
    pendingObsidianSyncTaskIds = pendingObsidianSyncTaskIds.filter { openTaskIds.contains($0) }
  }

  // MARK: TaskMutationHost

  var currentTask: CheckvistTask?

  var currentParentId: Int = 0

  func isDescendant(_ task: CheckvistTask, of ancestorId: Int) -> Bool {
    isDescendant(task, of: ancestorId, in: tasks)
  }

  private func isDescendant(
    _ task: CheckvistTask, of ancestorId: Int, in tasks: [CheckvistTask]
  ) -> Bool {
    var parentId = task.parentId
    var guardCounter = 0
    while let current = parentId, current != 0, guardCounter < tasks.count + 1 {
      if current == ancestorId { return true }
      parentId = tasks.first(where: { $0.id == current })?.parentId
      guardCounter += 1
    }
    return false
  }

  func clampSelectionToVisibleRange() {
    clampSelectionCallCount += 1
  }

  var lastUndoableAction: UndoableAction?
  var kanbanSelectedTaskId: Int?

  func fetchTopTask() async {
    fetchTopTaskCallCount += 1
    onFetchTopTask?()
  }

  var timerElapsedByTaskId: [Int: TimeInterval] = [:]

  var pendingObsidianSyncTaskIds: [Int] = []

  func savePendingObsidianSyncQueue(_ taskIds: [Int], listId: String) {
    pendingObsidianSyncTaskIds = taskIds
  }

  var dayLogTaskActions: [(taskId: Int, title: String, action: CheckvistTaskAction)] = []

  func recordDayLogTaskAction(taskId: Int, title: String, action: CheckvistTaskAction) {
    dayLogTaskActions.append((taskId, title, action))
  }

  func beginQuickAddEntry() {
    beginQuickAddCallCount += 1
  }

  func finishQuickAddEntry() {
    finishQuickAddCallCount += 1
  }

  func nextOccurrence(for completedTask: CheckvistTask)
    -> (dueDateString: String, savedRule: String)?
  {
    guard let rule = recurrenceRules[completedTask.id], !rule.isEmpty else { return nil }
    guard let due = nextOccurrenceDueDateString else { return nil }
    return (dueDateString: due, savedRule: rule)
  }

  func hasRecurrenceRule(forTaskId taskId: Int) -> Bool {
    guard let rule = recurrenceRules[taskId] else { return false }
    return !rule.isEmpty
  }

  func transferRecurrenceRule(fromTaskId: Int, toTaskId: Int, rule: String) {
    recurrenceRules[toTaskId] = rule
    recurrenceRules.removeValue(forKey: fromTaskId)
  }

  func clearRecurrenceRule(forTaskId taskId: Int) {
    recurrenceRules.removeValue(forKey: taskId)
  }

  func runTaskCompletionFeedback(taskId: Int) async -> Bool {
    completionFeedbackTaskIds.append(taskId)
    await duringCompletionFeedback?()
    return completionFeedbackSucceeds
  }

  /// Production wraps this in `withAnimation` so the rows settle over the gap.
  /// Headless, there is no transaction to open — but the body still has to run,
  /// because it is what actually removes the subtree.
  private(set) var listSettleAnimationCallCount = 0

  func withListSettleAnimation(_ body: () -> Void) {
    listSettleAnimationCallCount += 1
    body()
  }

  // MARK: SyncHost

  var taskMoveMode: TaskMoveMode = .siblingPosition

  var kanbanFilterParentId: Int?

  func moveTaskWithinKanbanColumn(taskId: Int, direction: Int) {
    kanbanNudges.append((taskId, direction))
  }

  func clampKanbanSelection() {
    clampKanbanSelectionCallCount += 1
  }

  func clearKanbanSelection() {
    clearKanbanSelectionCallCount += 1
  }

  func clampFocusSessionForTasks(_ tasks: [CheckvistTask]) {
    focusClampCallCount += 1
  }

  func reconcileTimersAfterFetch(previousTasks: [CheckvistTask], openTasks: [CheckvistTask]) {
    timerReconcileCallCount += 1
  }

  func markOnboardingCompleted() {
    onboardingCompletedCallCount += 1
  }

  func applyOptimisticUpdate(task: CheckvistTask, content: String?, due: String?) {
    optimisticMoveCalls.append((task.id, content, due))
  }
}
