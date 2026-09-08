import Foundation
import PriorityCore

/// The coordinator-shaped surface that `TaskMutationService` and `SyncService`
/// need, expressed without AppKit, SwiftUI, or any app-only model type.
///
/// Both services used to hold a `weak var coordinator: AppCoordinator?` and
/// reach through it into `taskListViewModel`, `quickEntry`, `kanban`, `timer`,
/// `integrations`, and friends. That made them impossible to compile — let
/// alone test — outside the Xcode app target, so the two files carrying the
/// optimistic-mutation and offline-replay logic had no unit coverage at all.
///
/// These protocols are the seam. Everything that genuinely needs the UI layer
/// (haptics, the completion animation, kanban column maths, the recurrence
/// rule store) is expressed as a *behaviour* the host performs rather than as a
/// manager object the service pokes at, so the services can move into
/// `PriorityAppLogic` and run against a test double. `AppCoordinator` provides
/// the production conformance in `AppCoordinator+ServiceHosts.swift`.
///
/// Neither service holds the host strongly: `AppCoordinator` owns the services,
/// so a strong back-reference would be a retain cycle.

// MARK: - Shared

/// How `SyncService.moveTask` should reorder, derived from the active root
/// view. Mirrors the app-only `RootTaskView` cases that behave differently:
/// `.all`, `.tags`, `.eisenhower`, and `.daily` all collapse to
/// `.siblingPosition`.
enum TaskMoveMode: Equatable, Sendable {
  case priorityQueue
  case kanbanColumn
  case dueDate
  case siblingPosition
}

/// The parts of the host both services use. Kept separate from the two
/// service-specific protocols so a test double can conform once.
@MainActor
protocol TaskServiceHost: AnyObject {
  /// The task list as currently filtered and ordered for display.
  var visibleTasks: [CheckvistTask] { get }
  /// Index of the selected task within `visibleTasks`.
  var currentSiblingIndex: Int { get set }
  /// The contiguous span of `tasks` covering `taskId` and all its descendants,
  /// or `nil` when the task isn't present.
  func subtreeBlockRange(for taskId: Int, in tasks: [CheckvistTask]) -> Range<Int>?
  /// Drops queued Obsidian syncs whose task is no longer open.
  func reconcilePendingObsidianSyncQueue(openTaskIds: Set<Int>, listId: String)
}

// MARK: - TaskMutationService

@MainActor
protocol TaskMutationHost: TaskServiceHost {
  // Selection and tree shape.
  var currentTask: CheckvistTask? { get }
  var currentParentId: Int { get }
  func isDescendant(_ task: CheckvistTask, of ancestorId: Int) -> Bool
  func clampSelectionToVisibleRange()

  /// The single-step undo slot. Mutations claim it as they go.
  var lastUndoableAction: UndoableAction? { get set }

  /// The kanban board's selected card, as a bare id so the service needn't
  /// know `KanbanManager`. An optimistic insert claims it immediately and then
  /// hands it over to the real id, or the new card loses selection the moment
  /// the server answers.
  var kanbanSelectedTaskId: Int? { get set }

  /// Re-reads the list from the active sync plugin. Lives on the host because
  /// it belongs to `SyncService`, which is a sibling rather than a dependency.
  func fetchTopTask() async

  // Per-task accumulated timer values, snapshotted and restored alongside the
  // task list so a rolled-back deletion doesn't lose recorded time.
  var timerElapsedByTaskId: [Int: TimeInterval] { get set }

  // Obsidian sync queue, snapshotted for the same reason.
  var pendingObsidianSyncTaskIds: [Int] { get }
  func savePendingObsidianSyncQueue(_ taskIds: [Int], listId: String)

  /// Nudges the user toward list setup when a mutation fails for want of one.
  func presentOnboardingDialogIfNeeded()

  // Quick Add. The service decides *whether* entry can start; the host owns the
  // focus/mode/text fields that make it happen.
  var quickAddPrefersSpecificLocation: Bool { get }
  var quickAddSpecificParentTaskId: Int? { get }
  func setQuickAddSpecificParentTask(id: Int)
  func beginQuickAddEntry(useSpecificLocation: Bool)
  func finishQuickAddEntry()

  // Recurrence. Rules are keyed by task id and stored by the host, so the
  // service never has to know the `RecurrenceRule` type.
  func nextOccurrence(for completedTask: CheckvistTask)
    -> (dueDateString: String, savedRule: String)?
  func hasRecurrenceRule(forTaskId taskId: Int) -> Bool
  func transferRecurrenceRule(fromTaskId: Int, toTaskId: Int, rule: String)
  func clearRecurrenceRule(forTaskId taskId: Int)

  /// Records a close/reopen/invalidate in the daily log.
  ///
  /// Expressed in primitives rather than as a log event because the event type
  /// lives in `PriorityCore`, which this module can't import (one file, one
  /// SPM target). The host translates. Only *accepted* mutations get here —
  /// something that failed and rolled back never happened.
  func recordDayLogTaskAction(taskId: Int, title: String, action: CheckvistTaskAction)

  /// Runs the haptic + strikethrough sequence for a task the user just closed.
  /// Returns `false` when the sequence was cancelled (the user navigated away
  /// mid-animation), in which case the close must not be sent.
  func runTaskCompletionFeedback(taskId: Int) async -> Bool

  /// Runs a list mutation inside the animation the remaining rows settle on.
  ///
  /// The host supplies the transaction because the animation is SwiftUI's and
  /// this module can't import it. Scoped to the mutation rather than declared
  /// on the list, deliberately: an `.animation(_:value:)` watching the visible
  /// tasks would also fire on every search keystroke and every root-view
  /// switch, animating rows in and out of a list the user is typing to filter.
  func withListSettleAnimation(_ body: () -> Void)
}

// MARK: - SyncService

@MainActor
protocol SyncHost: TaskServiceHost {
  /// Which reorder strategy the active root view implies.
  var taskMoveMode: TaskMoveMode { get }
  /// Root scope cursor. `SyncService` resets it when the list changes or the
  /// kanban filter parent disappears.
  var currentParentId: Int { get set }

  // Kanban. Column membership and ordering are app-only concerns, so the host
  // takes the whole operation rather than exposing `KanbanColumn`.
  var kanbanFilterParentId: Int? { get set }
  func moveTaskWithinKanbanColumn(taskId: Int, direction: Int)
  func clampKanbanSelection()
  func clearKanbanSelection()

  func clampFocusSessionForTasks(_ tasks: [CheckvistTask])

  /// Carries accumulated timer values across a refetch (reassigning a closed
  /// task's time to its surviving parent) and stops the timer if its task is
  /// gone. Lives on the host because the reassignment policy is in
  /// `PriorityCore`, which `PriorityAppLogic` doesn't link.
  func reconcileTimersAfterFetch(previousTasks: [CheckvistTask], openTasks: [CheckvistTask])

  /// Marks first-run onboarding satisfied once a real list has loaded.
  func markOnboardingCompleted()

  /// Applies a content/due edit optimistically and syncs it in the background.
  ///
  /// Owned by `TaskMutationService`, which is a sibling of `SyncService` rather
  /// than a dependency — so, like `fetchTopTask` in the other direction, it is
  /// reached through the host.
  func applyOptimisticUpdate(task: CheckvistTask, content: String?, due: String?)
}

// MARK: - TaskListViewModel

/// The five app-only managers `TaskListViewModel` reads, as a single read-only
/// surface.
///
/// The view model is the most load-bearing untested type in the app: it owns
/// `cacheVersion`, whose entire job is to be correct about SwiftUI observation,
/// and the visibility pipeline every list view renders from. It could not be
/// reached from a test because it named `NavigationState`, `TimerManager`,
/// `QuickEntryManager`, `PreferencesManager` and `KanbanManager` concretely,
/// and those pull in the whole app.
///
/// Everything it actually needs from them is read-only and scalar — which is
/// why this is worth doing at all. `AppCoordinator` provides the production
/// conformance in `AppCoordinator+ServiceHosts.swift`.
///
/// Reads go through here rather than being copied in, so SwiftUI's observation
/// still registers on the underlying `@Observable` managers: the access happens
/// inside their real getters either way.
@MainActor
protocol TaskListViewModelHost: AnyObject {
  /// The task whose children are being shown; 0 at the root.
  var currentParentId: Int { get }
  /// Selected index within the current level.
  var currentSiblingIndex: Int { get }
  /// Whether a search is narrowing the list.
  var isSearchFilterActive: Bool { get }
  var searchText: String { get }
  /// Accumulated time per task, for the roll-up columns.
  var timerElapsedByTaskId: [Int: TimeInterval] { get }
  /// Whether rows show their ancestor path.
  var showsTaskBreadcrumbContext: Bool { get }
  /// The kanban board's own selection, which replaces the list's when the
  /// board is the active view.
  var kanbanCurrentTask: CheckvistTask? { get }
  /// The matrix's own selection, for the same reason — an id here rather than a
  /// task, because the view model can resolve it from a cache it already keeps.
  var matrixSelectedTaskId: Int? { get }
}
