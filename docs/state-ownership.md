# State Ownership Map

> Navigation reference for "where does this piece of state actually live, who derives
> from it, and what happens when it changes." Written to cut through the
> `AppCoordinator` forwarding layer — many properties you reach through
> `AppCoordinator` are getters/setters into one of the objects below.
>
> Keep this current when state moves between owners (it's the thing the Phase-3
> decomposition in `ARCHITECTURE_IMPROVEMENT_PLAN.md` is gradually making true).

## The data-flow spine (read this first)

```
 raw truth                         fan-out            derived view              UI
┌────────────────────┐         ┌──────────────┐   ┌──────────────────┐   ┌───────────┐
│ TaskRepository      │ didSet  │ Cache        │   │ TaskListViewModel │   │ SwiftUI   │
│ NavigationState     │────────▶│ Invalidation │──▶│ .cache (CacheState)│─▶│ views     │
│ + feature managers  │ .invalidate()  Bus     │   │ rebuilt lazily    │   │ (@Observable)
└────────────────────┘         └──────────────┘   └──────────────────┘   └───────────┘
```

1. A cache-relevant `var` changes on a producer → its `didSet` calls `cacheInvalidationBus.invalidate()`.
2. The bus (`CacheInvalidationBus.swift`) fans out to its one subscriber: `AppCoordinator`
   (registered in `LifecycleController`), which calls `TaskListViewModel.invalidateCaches()`.
3. `invalidateCaches()` only sets the dirty flag. The rebuild happens **lazily**, on the next
   read of `TaskListViewModel.cache` (or of any accessor that calls
   `ensureVisibleTasksCacheValid()`).
4. That rebuild reconstructs the *entire* derived cache (visible tasks, tag index, due buckets,
   priority ranks, rolled-up timer elapsed) from the raw state, delegating math to the pure
   engines (`TaskVisibilityEngine`, `TaskFilterEngine`, `TimerStore`).
5. Views observe and re-render.

Invalidation is coarse: any producer change marks the whole cache dirty and the next read
triggers a full rebuild. Fine for menu-bar-sized lists; not granular.

Rebuilding lazily rather than eagerly matters because writes arrive in bursts — deleting a task
touches `tasks`, both priority queues and the eisenhower levels, which is four invalidations for
one user action. Reading `cache` always validates first, so external readers
(`KanbanManager`, `KanbanTaskDataSourceAdapter`) cannot observe a stale snapshot.
Inside `TaskListViewModel`, use the private `cacheStorage` to avoid re-entering the validity
check on hot paths.

## Owners

### `TaskRepository` — the source of truth for tasks, auth, lists
Raw state (each cache-relevant `var` fires the bus from `didSet`):

| State | Fires bus | Notes |
|---|---|---|
| `tasks: [CheckvistTask]` | ✓ | the list itself |
| `availableLists: [CheckvistList]` | ✓ | |
| `priorityTaskIdsByParentId: [Int:[Int]]` | ✓ | per-parent priority queues (0 = root) |
| `absolutePriorityTaskIds: [Int]` | ✓ | global absolute-priority queue |
| `taskEisenhowerLevels: [Int:EisenhowerLevel]` | ✓ | |
| `checkvistIntegrationEnabled: Bool` | ✓ | also persists + fires `onCheckvistIntegrationEnabledChanged` |
| `isNetworkReachable: Bool` | ✓ | offline↔online transitions |
| `username` / `remoteKey` / `listId` | — | persist to prefs + fire `onUsernameChanged`/`onRemoteKeyChanged`/`onListIdChanged`; `listId` also reloads priority/eisenhower queues |
| `isLoading` / `errorMessage` | — | UI status, not cache-relevant |
| `pendingTaskMutations/Creates/Actions/Deletes` | — | `@ObservationIgnored` offline replay queues; write-through to `PendingOfflineWorkStore` via the `enqueuePending*` helpers |
| `fetchGeneration` / `completionSuppressionByTaskId` | — | `@ObservationIgnored`; the in-flight fetch coordination described below |

Derived (don't re-derive these elsewhere — Finding 3/4 in the plan):
`hasCredentials`, `canAttemptLogin`, `hasListSelection`, **`canSyncRemotely`** (the single
source of truth for online vs. offline routing), `activeCredentials`, **`activeSyncPlugin`**
(returns Checkvist plugin or `OfflineTaskSyncPlugin` — callers never branch on online/offline
themselves), `prioritizedTaskIds`, `absolutePrioritizedTaskIds`, `hasPendingOfflineWork`,
`offlineOpenTaskCount`.

Also owns **`expandedTaskIds: Set<Int>`** — which tasks show their children inline. It lives
here rather than on `NavigationState` because it is list-scoped and persisted
(`ListScopedTaskIDStore`, key `expandedTaskIdsByListId`), so switching lists has to swap it
the way it swaps the priority queues. `reconcilePriorityQueueWithOpenTasks()` prunes ids whose
tasks are gone.

**In-flight fetch coordination.** Fetches are issued from several places at once — the
become-active auto-refresh, the refresh button, every mutation's own refetch, the reorder
resync, the offline flush — and nothing serialises them, so the repository arbitrates between
their answers. `beginFetchGeneration()` stamps each fetch; `isLatestFetchGeneration(_:)` lets
`SyncService` drop a response that a newer fetch has already superseded, so answers can't land
out of order. `suppressLocallyCompletedTasks(_:)` / `unsuppressLocallyCompletedTasks(_:)` /
`filteringLocallyCompletedTasks(from:generation:)` cover the other half: a fetch already on the
wire when the user completes a task answers with the task still open, and applying that
verbatim put the completed row back on screen. Optimistic completions register here (see
`TaskMutationService.applyOptimisticCompletion`) and are lifted when the completion is undone —
a rolled-back close, or a reopen. The offline `pendingTaskActions`/`pendingTaskDeletes` queues
feed the same filter without a generation, because a close that hasn't gone out stays true for
as long as it is queued — including across a relaunch.

### `NavigationState` — where the user is in the tree
| State | Fires bus |
|---|---|
| `currentParentId: Int` | ✓ |
| `currentSiblingIndex: Int` | — |
| `rootScopeFocusLevel: Int` | — |
| `isPopoverVisible: Bool` | — | *(the popover is gone; the flag is not yet)*

### `TaskListViewModel` — the derived view + the view-shaping toggles
Owns the toggles that shape what's visible, *and* the rebuilt `cache`. These `didSet`s call
`invalidateCaches()` **directly** (not via the bus — the VM is the bus's consumer):
`hideFuture`, `rootTaskView`, `selectedRootDueBucketRawValue`, `selectedRootTag`,
`showChildrenInMenus`. The cache lives in the private, `@ObservationIgnored` `cacheStorage` and
is exposed as `var cache: CacheState`, whose getter rebuilds via
`ensureVisibleTasksCacheValid()` when dirty.

Also owns the cache-derived view helpers consolidated here in step 3.7d (they read the
`cache` directly rather than forwarding through `AppCoordinator`): `priorityBadgeLabel` /
`eisenhowerBadgeLabel` / `priorityRank` / `absolutePriorityRank` / `priorityPath`,
`rootDueBucket`, `rootDueSectionHeader` / `remainderSectionHeader` / `rootDueSectionCount` /
`remainderStartIndex`, `rootLevelTagNames`, `isDescendant`, and the outline accessors
(`outlineRows` / `outlineDepth(atVisibleIndex:)` / `isExpanded`). `visibleTasks` is the
flattened outline: `TaskVisibilityEngine` picks the rows a tab wants, then
`TaskOutlineBuilder` inserts the children of expanded rows after them, with
`cache.outlineDepths` holding the indent per row. Views read these via
`@Environment(TaskListViewModel.self)`.


### Feature managers (each owns its slice + persists to `PreferencesStore`)
| Manager | Owns | Cache-relevant |
|---|---|---|
| `TimerManager` | `timedTaskId`, `timerByTaskId`, `timerRunning`; `timerMode`/`timerBarLeading` (prefs-backed) | `timerByTaskId` feeds rolled-up elapsed in the cache |
| `KanbanManager` | `kanbanColumns`, `kanbanFocusedColumnIndex`, `kanbanSelectedTaskId`, `kanbanFilterSubtasks`, `kanbanFilterParentId`, `addingToColumnId`, `addText`, `manualOrderByColumnId` | reads tasks/cache via `dataSource` (the coordinator) |
| `QuickEntryManager` | `searchText` (fires bus), `quickEntryText`, `quickEntryMode`, `isQuickEntryFocused`, `editCursorAtEnd`, `pendingDeleteConfirmation`, `completingTaskId`, `commandSuggestionIndex`, `keyBuffer` | `searchText`/mode drive `isSearchFilterActive` → visibility |
| `FocusSessionManager` | `promptTaskId`, `session`, `phase`, `durationMinutes`, `breakDurationMinutes`, `lastFocusedTaskId` | drives focus alerts; pauses timer via `onFocusBlockEnded` |
| `StartDateManager` | `taskStartDatesByTaskId` | yes (affects `hideFuture` visibility) |
| `RecurrenceManager` | `recurrenceRulesByTaskId` | no (consulted on completion) |
| `PreferencesManager` | prefs-backed settings: appearance mode, hotkeys, the Quick Add list, focus behaviour, `confirmBeforeDelete`, `launchAtLogin`, etc. The theme pick and font choices are `ThemeManager`'s | no |
| `IntegrationCoordinator` | `obsidian/googleCalendar/mcpIntegrationEnabled`, `obsidianInboxPath`, `mcpServerCommandPath`, `pendingObsidianSyncTaskIds`, `googleCalendarEventLinksByTaskKey` | reads tasks/listId/currentTask/credentials via `dataSource` |

### `AppCoordinator` — genuinely owns (everything else is forwarding)
`statusMessage` (auto-clears after 3s), `onboardingCompleted`, `activeOnboardingDialog`,
`dismissedOnboardingDialogs`, `isApplyingLaunchAtLoginChange`, `orderedRootTaskViews`
(stored directly in `UserDefaults`), and the extracted **services**: `taskNavigationService`,
`taskMutationService`, `syncService`, `undoService`, `lifecycle`, plus `commandExecutor` and
`reachabilityMonitor`.

The Phase-3 forwarder cull is finished: `AppCoordinator` no longer re-exposes
`tasks` / `currentParentId` / `hideFuture` / `username` / `listId` / `availableLists` /
`cache` / `activeCredentials` / `errorMessage` / `isLoading` / `remoteKey` /
`taskEisenhowerLevels` etc. Read those directly from their owner: views via
`@Environment(TaskRepository.self)` / `@Environment(NavigationState.self)` /
`@Environment(TaskListViewModel.self)`; non-view callers via `manager.repository.X` /
`manager.navigationState.X` / `manager.taskListViewModel.X`. The Phase-3 services
(`SyncService`, `TaskMutationService`, `TaskNavigationService`) all take a strong
`TaskRepository` reference in their initializers and read auth/list state from there
directly — no coordinator forwarder hop.

`SyncService` and `TaskMutationService` no longer hold `AppCoordinator` at all: they take a
`weak` `SyncHost` / `TaskMutationHost` (`Takt/TaskServiceHosts.swift`), which
`AppCoordinator` conforms to in `AppCoordinator+ServiceHosts.swift`. Anything those services
need from a sibling manager — selection, undo, quick-entry focus, kanban ordering, recurrence
rules, the completion haptics — is a host member rather than a `coordinator.someManager.X`
reach-through, which is what lets both services live in `TaktAppLogic` and be tested
against `StubTaskServiceHost`. When you give one of them a new dependency, add it to the host
protocol.

## Cache-invalidation producer list (who fires the bus)

`TaskRepository` (`tasks`, `availableLists`, `priorityTaskIdsByParentId`,
`absolutePriorityTaskIds`, `taskEisenhowerLevels`, `expandedTaskIds`,
`checkvistIntegrationEnabled`, `isNetworkReachable`), `NavigationState` (`currentParentId`), `QuickEntryManager`
(`searchText`), `TimerManager` (`timerByTaskId`), `StartDateManager` (`taskStartDatesByTaskId`),
`KanbanManager`, `FocusSessionManager`. The lone **subscriber** is `AppCoordinator` →
`TaskListViewModel.invalidateCaches()`.

`TaskListViewModel`'s own view-shaping toggles bypass the bus and call `invalidateCaches()`
directly, because the VM *is* the thing the bus ultimately notifies.

## How a mutation flows (worked example: mark current task done)

1. View / keybind → `AppCoordinator.markCurrentTaskDone()` (forwarder) → `TaskMutationService`.
   The service claims the task id for the duration, animation included, so a second press
   inside the ~200ms completion feedback can't close the same task twice.
2. Service mutates `repository.tasks` optimistically → `didSet` fires the bus → cache rebuilds → UI updates immediately.
   It also registers the removed ids with the repository's completion suppression, so a fetch
   that was already in flight can't answer the task back into existence.
3. Service calls `repository.activeSyncPlugin.performTaskAction(...)` async.
   - Online success: done.
   - Offline / failure: roll back the local mutation (re-inserting just the removed subtree, not
     the whole pre-removal array, so anything that landed meanwhile survives) and lift the
     suppression, **or** stash the work in `repository.pendingTask*` (write-through to disk). On
     reconnect, `SyncService.flushPendingTaskMutations()` replays.

This optimistic-then-sync-then-rollback-or-enqueue shape recurs across mutations; see
`AppCoordinator.applyOptimisticMoveAndSync` and the `TaskMutationService` mutation methods.
</content>
</invoke>

## One shell, one set of state

There used to be two: the menu bar panel and the main window hosted the *same*
`PopoverView` over the *same* `AppCoordinator`, differing only in a `\.shellMode`
that decided chrome. The panel and that view are gone, and with them the shell
mode. `MainWindowController` is the only host of the legacy managers described
above, and the workspace window is the only surface.

**They are mirrors, not independent views, and that is a property of the state
model rather than a decision that can be revisited cheaply.**
`TaskListViewModel.cache` is derived from `rootTaskView`, `hideFuture`,
`searchText` and the `NavigationState` cursor. One view model therefore cannot
serve two surfaces showing different tabs — switching tab in the window
switches it in the panel, by construction.

Making them independent means extracting a per-window context holding
`NavigationState`, `TaskListViewModel`, `QuickEntryManager`, the kanban and
daily selections, `statusMessage`, and the celebration / shortcut-overlay flags,
while `TaskRepository`, `PreferencesManager`, `TimerManager` and the
integrations stay global. It also means multicasting `CacheInvalidationBus`,
which today has exactly one subscriber. The host protocols in
`TaskServiceHosts.swift` are the seam that already exists for it.

Two windows on *different lists* is further still: `TaskRepository.listId` is a
single global whose `didSet` swaps all four `ListScoped*` stores, and the
fetch-generation arbitration assumes one list in flight.

### Failure state

Nothing in the app retained a failure for longer than three seconds:
`repository.errorMessage` is overwritten by the next failure and cleared by the
next fetch, `AppCoordinator.statusMessage` erases itself on a timer, and
`IntegrationCoordinator.onError` dropped what it was given. `DiagnosticsLog` is
the bounded in-memory record that closes that gap. It is fed from
`LifecycleController`, chained onto the existing `onError` / `onStatus` /
`onErrorMessageSet` handlers — **those are single closure slots, not multicast**,
so anything else that wants to observe them has to chain too, not replace.

## The desktop workspace: one refresh per action

Everything above is the legacy Checkvist stack. The desktop window reads
`WorkspaceViewModel`, which does not use the bus; it refreshes through
`WorkspaceViewModel+Refresh.swift`.

- A reload called inside `perform { }` (a write) or `batchingRefreshes { }`
  (navigation) only marks a `WorkspaceRefresh` flag — `.outline`, `.board`,
  `.sidebar`, `.dailies`, `.nextUp`. When the outermost block ends the marks are
  served once, in that order, and `perform`'s side effects (draft refresh,
  `onLocalWrite`) run once. A reload called outside any block runs at once.
- Reading `visibleNavigationTasks` mid-block serves the marks first, so code
  that changes scope and then asks what is on screen sees the new scope. Any
  other read of derived state after a reload in the same block must call
  `flushPendingRefresh()` itself.
- Each list is read once per refresh (`WorkspaceListTree`, cached in
  `listTreeCache`); the outline, board, descendants and sidebar are shaped from
  it in memory. Pass `refreshSidebar: false` when a change cannot touch a list
  or a count — a plain task's status or title.
- `.nextUp` is ranked off the main thread (`WorkspaceNextUpSnapshot`) and
  applied when it lands, unless something was written meanwhile
  (`writeEpoch`), in which case it is read again. `reloadNextUpNow()` is the
  synchronous form for the few callers that read the ladder on the next line.
- After a refresh `taskCache` holds every task a surface names — board, outline,
  nested lists, done rail, the day, the selection, the running block — so
  `task(withID:)` in a view body is a lookup, not a query. `dayItems`, the
  undo/redo labels and the outline's grouping are stored, not computed.
- Views take selection as values (`isSelected`, `hasKeyboard`,
  `selectedCardID`) from a parent that reads `selectedTaskID` once, so an arrow
  key re-renders the two rows it moved between.
