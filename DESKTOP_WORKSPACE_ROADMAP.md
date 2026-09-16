# Priority desktop workspace roadmap

## Purpose

Turn Priority from its original Checkvist-first menu-bar utility into a local-first macOS planning app: fast list outlines and focus flow in the spirit of Blitzit, with the planning, time-tracking, reporting, and project capabilities associated with Super Productivity.

The local SQLite workspace is the source of truth. Checkvist and other services are optional import/export/integration edges, never a requirement for opening, editing, or focusing work.

## Current baseline

Already implemented and committed:

- Main app opens as a normal desktop macOS app (`LSUIElement = NO`), with a simple menu-bar launcher.
- SQLite + GRDB workspace database at `~/Library/Application Support/Priority/priority.sqlite`.
- Workspace, folders, lists, nested task outlines, notes, completion, basic inspector.
- Manual focus queue, persisted focus session, focus panel, floating timer.
- Desktop keyboard navigation: task selection/tree traversal, completion, focus, list switching, task/list/folder creation, shortcut reference.
- One-time migration of legacy offline tasks and the currently loaded legacy Checkvist list.

Relevant implementation locations:

| Area | Files |
| --- | --- |
| Local schema and persistence | `Sources/PriorityWorkspace/WorkspaceModels.swift`, `Sources/PriorityWorkspace/WorkspaceStore.swift` |
| Desktop state and migration | `Priority/WorkspaceViewModel.swift` |
| Desktop UI | `Priority/WorkspaceDesktopView.swift`, `Priority/MainWindowController.swift` |
| Focus floating timer | `Priority/LocalFloatingFocusTimer.swift` |
| Startup and legacy import trigger | `Priority/AppDelegate.swift` |

## Non-negotiable product rules

1. Local first. All normal task operations work with no account or network connection.
2. No destructive migration. Import must copy source data, be idempotent, and report results.
3. The desktop workspace is the only task-editing surface. The menu bar is a launcher/status surface only.
4. Preserve keyboard parity. Every common task operation must be possible without a mouse and be discoverable in the shortcut reference.
5. Prefer small, reversible database migrations and test each migration with fixture databases.
6. Do not delete legacy source/data until its desktop replacement exists and migration/export is verified.

## Phase 1 — Finish the daily workspace

Goal: make Lists + Focus viable for daily use without relying on the old app.

### Lists and folders

- Treat active lists as sub-lists of a virtual Everything scope. Its views should aggregate tasks while preserving each task's list, project hierarchy, and an explicit destination for new work.
- Rename, archive, restore, delete, and reorder lists/folders. *Renaming is done in place — double-click, context menu, or ⌘R — rather than through the settings sheet.*
- Support nested folders in both persistence and sidebar presentation.
- Add move-list-to-folder, move-folder, and keyboard commands.
- Add a list settings inspector: color, archive state, task count.

### Task editing and organization

- Add full task inspector fields: due date, estimate, tags, priority, recurrence, links/attachments as appropriate.
- Create/delete/rename/reorder/move/indent/outdent tasks.
- Support moving tasks between lists while preserving subtrees.
- Implement multi-selection and bulk complete/move/tag/delete.
- Add drag-and-drop, but keep an equivalent keyboard operation for every drag action.
- ~~Add undo/redo for all local mutations.~~ Done: every mutating store write runs through `journalledWrite`, which records row-level before/after images under one step per operation. ⌘Z / ⌘⇧Z.

### Fast capture and discovery

- ~~Make the global quick-add hotkey create a local Inbox task and focus the desktop composer.~~ Done: the hotkey selects the Inbox, leaves the focus screen, and puts the caret in the composer.
- ~~Add local full-text search across task title and notes (SQLite FTS is preferred).~~ Done: external-content FTS5 over title and notes, kept level by triggers. ⌘F.
- Add filters for open/completed, due, tags, priority, and estimate.
- Add a command palette for navigation and creation; do not route it through legacy Checkvist state.

### Acceptance criteria

- A user can create a project outline, reorganize it, complete work, and find a task entirely offline.
- No common operation requires the legacy popover or a Checkvist credential.
- Keyboard reference documents every new action.
- Store tests cover tree moves, ordering, deletion/archival, undo boundaries, and FTS/filter behavior. *Filters are the part still missing; the rest is covered.*

## Phase 2 — Data safety and complete migration

Goal: make local data trustworthy before adding more views.

### Export, restore, and backups

- Add versioned JSON export containing workspace, folders, lists, tasks, focus data, and metadata.
- Add import/restore preview with validation and a clear merge/replace choice.
- Add automatic rotating backups in Application Support and a visible “last backup” status.
- Add database integrity check, migration error reporting, and recovery instructions.

### Legacy/Checkvist import

- Build an import assistant with source selection and a task/list count preview.
- Import all configured Checkvist lists, not only the currently loaded list.
- Preserve source-list names, hierarchy, notes, ordering, due dates, and completed/invalidated status where supplied by the source.
- ~~Track an immutable external source ID in local metadata so re-running import merges safely instead of duplicating tasks.~~ Done: `tasks.sourceSystem` + `tasks.sourceId` behind a partial unique index. A re-import updates content in place and leaves local placement alone.
- Provide an import result report: created, updated, skipped, orphaned-parent repairs, and errors. *`TaskImportOutcome` now carries created/updated; the rest is unreported.*
- Treat Checkvist sync as optional and explicitly separate “one-time import” from future two-way sync.

### Acceptance criteria

- Export then restore into an empty profile preserves the local workspace exactly.
- Re-running any import is idempotent.
- An import failure never leaves a partially committed source list.
- Automated tests cover old offline payloads, multiple Checkvist lists, completed tasks, malformed trees, duplicate IDs, and interrupted imports.

## Phase 3 — Planner views

Goal: give the local workspace the planning loop users expect from a desktop task app.

### Inbox, Today, Upcoming

- ~~Make Inbox a first-class system list.~~ Done: `task_lists.systemRole`. Found by role rather than by name, so renaming it is safe; archiving and deleting it are refused.
- Implement Today as a local planning view: manually include tasks, schedule tasks, reorder the day, and show overdue/upcoming work.
- Add Upcoming grouped by day/week and a clean unscheduled view.
- Ensure changing Today does not change a source list unless the user explicitly moves/schedules a task.

### Projects and visual modes

- Add project metadata and project overview/progress.
- Add local Kanban and Eisenhower views backed by workspace metadata, not old popover state.
- Add saved filters/views for contexts, tags, and projects.
- Add a calendar/time-block view once dates and estimates are stable.

### Acceptance criteria

- A user can capture into Inbox, plan Today, execute in Focus, and review/reshape a project without leaving the desktop app.
- Today and visual views are alternate projections of the same local tasks; no duplicate task stores.

## Phase 4 — Complete Focus and time tracking

Goal: match the low-friction focus flow of Blitzit and add Super Productivity-style time awareness.

### Focus sessions

- Add pause/resume, work/break phase transitions, skip, configurable durations, and session completion behavior.
- Support reordering/removing queue items while focused.
- Restore an active session correctly after relaunch, including timer elapsed time.
  *Each block is now timed from its own start rather than the session's, so a queued
  task is no longer credited the previous task's sitting.*
- Add local notifications and optional sound; notifications must degrade safely when permission is denied.

### Time tracking and review

- ~~Score a finished focus block by how well the work went.~~ Done: a block is worth
  the minutes it took, to one decimal place, multiplied by a quality multiplier the
  user gives when they press Done. Five presets from Scattered (×0.5) to Flow (×2.0),
  or any multiplier up to ×5. Scores are kept in `focus_awards` with the task's title
  copied in, so renaming or deleting the task later cannot rewrite what was earned.
- Add manual start/stop tracking per task and project.
- Persist work logs independently from task completion.
- Add daily/weekly reports: focused time, estimates versus actuals, completed work, and project distribution.
- Allow CSV/JSON export of time logs.

### Acceptance criteria

- Timer state survives quit/relaunch without double-counting.
- Completing a focused task advances the queue predictably.
- Reports are calculated locally and have deterministic test fixtures.

## Phase 5 — Optional integrations

Goal: add value at the boundary without compromising local ownership.

- Checkvist: import first; only design two-way sync after conflict policy, source IDs, delete semantics, and offline queue behavior are specified and tested.
- Calendar: optional time-block export/import with an explicit mapping and no invisible task edits.
- Obsidian/AFFiNE/MCP: retain as optional plugins; convert any task mutation path to target the local workspace first.
- Add integration status, permissions, retry controls, and a clear “disconnect without deleting local data” flow.

## Phase 6 — Remove legacy surface

Only begin after Phases 1–3 have replacements and migration/export are proven.

1. Remove all calls and shortcuts that mutate legacy Checkvist/popover task state.
2. Replace remaining legacy settings with workspace/integration settings.
3. Remove the old popover controller, popover views, popover layout, old task keyboard router, and their build references.
4. Remove legacy-only managers after proving no plugin or CLI depends on them.
5. Rewrite README/onboarding/help around the desktop local-first workflow.
6. Run a clean install/migration/export/restore test before deleting compatibility code.

Do not delete the legacy local payload automatically; keep it until one successful export/backup after migration, then offer the user an explicit cleanup action.

## Suggested delivery sequence

1. Phase 1 task/list CRUD, moving/reordering, local quick capture, search.
2. Phase 2 export/backup/import assistant and durable external IDs.
3. Phase 3 Inbox + Today + Upcoming.
4. Phase 4 focus pause/break/time logs/reports.
5. Phase 3 visual planner modes and calendar.
6. Phase 5 integrations.
7. Phase 6 legacy removal.

Each item should land as a coherent, tested commit. Do not combine schema changes, broad UI redesign, and legacy deletion in one change.

## Verification checklist for every milestone

- `swift test`
- `xcodebuild -project 'Priority.xcodeproj' -scheme 'Priority' -configuration Debug -destination 'platform=macOS' build`
- Manual keyboard-only smoke test for the changed workflow.
- Relaunch test to verify persistence.
- Offline test with network unavailable where relevant.
- Migration/export test whenever a schema or source mapping changes.

## Definition of done

Priority is done with this transition when a new user can create and organize local work, plan Today, focus, track time, export/restore safely, and optionally import/sync integrations — all from the desktop workspace — with no legacy menu-bar task interface or Checkvist account required.
