# State Ownership Map

> Navigation reference for "where does this piece of state actually live, who derives
> from it, and what happens when it changes." Written to cut through the
> `AppCoordinator` forwarding layer — many properties you reach through
> `AppCoordinator` are getters/setters into one of the objects below.
>
> Keep this current when state moves between owners (it's the thing the Phase-3
> decomposition in `ARCHITECTURE_IMPROVEMENT_PLAN.md` is gradually making true).

## The data-flow spine (read this first)

There are two stacks, and only one of them draws anything.

- **The desktop workspace** — `WorkspaceViewModel` over `WorkspaceStore` and
  the Rust core — is the whole UI. It refreshes itself; see the last section.
- **The Checkvist stack** — `TaskRepository`, `NavigationState`,
  `SyncService`, `TaskMutationService` and the feature managers below — is
  what Checkvist sync and import still run on. Nothing on screen shows its
  tasks any more, so nothing derives a view of them: the lazily rebuilt cache
  (`TaskListViewModel`, `CacheState`) and the `CacheInvalidationBus` that
  marked it dirty were deleted in Phase 6 of the desktop roadmap, with the
  visibility engines it ran. Readers of the Checkvist state read the owner
  directly.

## Owners

### `TaskRepository` — the source of truth for the Checkvist tasks, auth, lists
Raw state:

| State | Notes |
|---|---|
| `tasks: [CheckvistTask]` | the list itself |
| `availableLists: [CheckvistList]` | |
| `priorityTaskIdsByParentId: [Int:[Int]]` | per-parent priority queues (0 = root) |
| `absolutePriorityTaskIds: [Int]` | global absolute-priority queue |
| `taskEisenhowerLevels: [Int:EisenhowerLevel]` | |
| `checkvistIntegrationEnabled: Bool` | persists + fires `onCheckvistIntegrationEnabledChanged` |
| `isNetworkReachable: Bool` | offline↔online transitions |
| `username` / `remoteKey` / `listId` | persist to prefs + fire `onUsernameChanged`/`onRemoteKeyChanged`/`onListIdChanged`; `listId` also reloads priority/eisenhower queues |
| `isLoading` / `errorMessage` | status |
| `pendingTaskMutations/Creates/Actions/Deletes` | `@ObservationIgnored` offline replay queues; write-through to `PendingOfflineWorkStore` via the `enqueuePending*` helpers |
| `fetchGeneration` / `completionSuppressionByTaskId` | `@ObservationIgnored`; the in-flight fetch coordination described below |

Derived (don't re-derive these elsewhere — Finding 3/4 in the plan):
`hasCredentials`, `canAttemptLogin`, `hasListSelection`, **`canSyncRemotely`** (the single
source of truth for online vs. offline routing), `activeCredentials`, **`activeSyncPlugin`**
(returns Checkvist plugin or `OfflineTaskSyncPlugin` — callers never branch on online/offline
themselves), `prioritizedTaskIds`, `absolutePrioritizedTaskIds`, `hasPendingOfflineWork`,
`offlineOpenTaskCount`.

Also owns **`expandedTaskIds: Set<Int>`** — which tasks showed their children inline in the
popover. Nothing reads it since the legacy list went, but it is list-scoped and persisted
(`ListScopedTaskIDStore`, key `expandedTaskIdsByListId`), so it is still swapped on a list
switch and pruned by `reconcilePriorityQueueWithOpenTasks()` rather than deleted.

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

### `NavigationState` — the Checkvist cursor
| State | Notes |
|---|---|
| `currentParentId: Int` | the cursor's level; `SyncService` resets it to 0 on a list switch |
| `currentSiblingIndex: Int` | the cursor's index within that level |
| `rootScopeFocusLevel: Int` | |
| `isPopoverVisible: Bool` | *(the popover is gone; the flag is not yet)* |

No surface shows or moves the cursor. The sync and mutation services still
select into it after a fetch, an insert or a removal, so `AppCoordinator`
answers it for them (`AppCoordinator+ServiceHosts.swift`): `visibleTasks` is
the tasks at `currentParentId` in list order (`TaskFilterEngine.cursorLevel`),
`currentTask` the one at the clamped `currentSiblingIndex`, and
`subtreeBlockRange` / `isDescendant` are `TaskFilterEngine`'s over
`repository.tasks`. `taskMoveMode` still reads the root view the popover last
persisted (`PreferencesStore` key `rootTaskView`). `IntegrationDataSource`'s
`currentTask` is the same cursor task.

The day log's plan (`DailyLogDataSourceAdapter.plannedTaskIdsForToday`) is
`DayLogPlan` over `repository.tasks` and `StartDateManager`'s start dates. It
stays a plan of Checkvist tasks because the log keys every event by Checkvist
id and only the Checkvist path records completions in it.

### Feature managers (each owns its slice + persists to `PreferencesStore`)
| Manager | Owns | Notes |
|---|---|---|
| `TimerManager` | `timedTaskId`, `timerByTaskId`, `timerRunning`; `timerMode`/`timerBarLeading` (prefs-backed) | `timerByTaskId` is carried across a refetch by `reconcileTimersAfterFetch` |
| `QuickEntryManager` | `searchText`, `quickEntryText`, `quickEntryMode`, `isQuickEntryFocused`, `editCursorAtEnd`, `pendingDeleteConfirmation`, `completingTaskId`, `commandSuggestionIndex`, `keyBuffer` | the Quick Add host members set it |
| `FocusSessionManager` | `promptTaskId`, `session`, `phase`, `durationMinutes`, `breakDurationMinutes`, `lastFocusedTaskId` | drives focus alerts; pauses timer via `onFocusBlockEnded` |
| `StartDateManager` | `taskStartDatesByTaskId` | feeds the day log's plan |
| `RecurrenceManager` | `recurrenceRulesByTaskId` | consulted on completion |
| `PreferencesManager` | prefs-backed settings: appearance mode, hotkeys, the Quick Add list, focus behaviour, `confirmBeforeDelete`, `launchAtLogin`, etc. The theme pick and font choices are `ThemeManager`'s | |
| `IntegrationCoordinator` | `obsidian/googleCalendar/mcpIntegrationEnabled`, `obsidianInboxPath`, `mcpServerCommandPath`, `pendingObsidianSyncTaskIds`, `googleCalendarEventLinksByTaskKey` | reads tasks/listId/currentTask/credentials via `dataSource`; the Google Calendar page's "Create event from selected task" goes to the workspace's selection through `addSelectedWorkspaceTaskToGoogleCalendar` |

### `AppCoordinator` — genuinely owns (everything else is forwarding)
`statusMessage` (auto-clears after 3s), `showsDiagnostics` (the main window's diagnostics
sheet), `isApplyingLaunchAtLoginChange`, and the extracted **services**:
`taskMutationService`, `syncService`, `undoService`, `lifecycle`, plus `reachabilityMonitor`.

The Phase-3 forwarder cull is finished: `AppCoordinator` no longer re-exposes
`tasks` / `currentParentId` / `username` / `listId` / `availableLists` /
`activeCredentials` / `errorMessage` / `isLoading` / `remoteKey` /
`taskEisenhowerLevels` etc. Read those directly from their owner: views via
`@Environment(TaskRepository.self)` / `@Environment(NavigationState.self)`;
non-view callers via `manager.repository.X` / `manager.navigationState.X`. The Phase-3 services
(`SyncService`, `TaskMutationService`) both take a strong
`TaskRepository` reference in their initializers and read auth/list state from there
directly — no coordinator forwarder hop.

`SyncService` and `TaskMutationService` no longer hold `AppCoordinator` at all: they take a
`weak` `SyncHost` / `TaskMutationHost` (`Takt/TaskServiceHosts.swift`), which
`AppCoordinator` conforms to in `AppCoordinator+ServiceHosts.swift`. Anything those services
need from a sibling manager — selection, undo, quick-entry focus, recurrence rules, the
completion haptics — is a host member rather than a `coordinator.someManager.X`
reach-through, which is what lets both services live in `TaktAppLogic` and be tested
against `StubTaskServiceHost`. When you give one of them a new dependency, add it to the host
protocol.

## How a mutation flows (worked example: closing a task)

1. `TaskMutationService.taskAction` — reached today when a box is ticked in AFFiNE
   (`IntegrationCoordinator.onCloseTasks`); the current-task entry points that the popover's
   keys drove (`markCurrentTaskDone` and friends) no longer have a caller.
2. Service mutates `repository.tasks` optimistically.
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

## One shell, one set of state

There used to be two: the menu bar panel and the main window hosted the *same*
`PopoverView` over the *same* `AppCoordinator`, differing only in a `\.shellMode`
that decided chrome. The panel and that view are gone, and with them the shell
mode and the legacy task list view model both mirrored. `MainWindowController`
is the only host of the legacy managers described above, and the workspace
window is the only surface.

Two windows on *different Checkvist lists* would still be far off:
`TaskRepository.listId` is a single global whose `didSet` swaps all four
`ListScoped*` stores, and the fetch-generation arbitration assumes one list in
flight.

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
`WorkspaceViewModel`, which refreshes through
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
- The main pane's scope — one list, or Everything or a folder together — is
  read once (`WorkspaceScopeRead`) and kept resident between switches in
  `WorkspaceScopeCache` (`WorkspaceViewModel+ScopeCache.swift`) with the
  `changeStamp()` it was read at; the outline, board and matrix are shaped
  from it once and kept with it. A switch to a scope whose stamp still holds
  reads nothing. See `docs/performance.md` for what is resident, when it is
  dropped and what runs off the main thread. Pass `refreshSidebar: false`
  when a change cannot touch a list or a count — a plain task's status or
  title.
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
