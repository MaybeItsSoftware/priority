# Conditions audit

October 2026. How conditions work end to end, what goes wrong when you use
them from the keyboard, and what was done about each finding. Severity is
what the finding costs someone who relies on conditions every day: **high**
hides work or misreports it, **medium** costs keystrokes or trust, **low**
is polish.

## How they work

- A condition is a row in `task_conditions` (name, category, `isLocation`,
  archived). Location is the one exclusive category; the core keeps
  `isLocation` equal to "the category is Location" (`core/src/conditions.rs`).
- A task requires conditions in `task_metadata.planningJSON`
  (`requirementGroups`): every group must hold, and any one member of a group
  will do. A member written `!id` asks for that condition *not* to hold
  ("not Home"; `core/src/conditions/requirement.rs`). The editor's save
  validates them (`core/src/editor.rs`).
- What holds now is the **context**: active condition ids, an available-time
  window, a goal and an expiry. The ranking (`core/src/focus.rs`,
  `reasons`) holds back a task whose groups are not all met, which keeps it
  out of the day, the panel and next up.
- The Mac edits requirements with `cc` and the inspector; it sets the
  context and manages conditions in the right dock's Conditions tab. The
  phones set the same context on the Focus screen ("Where you are"), and the
  iPhone has a Conditions sheet.
- The context is one row per workspace, `focus_contexts`, synced since
  `v28_synced_focus_context`: every client, the CLI and the agent read and
  write the same row, and the last device to say where you are wins.

## Findings

| # | Severity | Finding | Fix |
|---|---|---|---|
| 1 | High | The context lived in each app's preferences (`UserDefaults`, Android settings). Nothing outside the running app could see it: the agent and the CLI could not tell why a task was held back, nor say "I'm at Campus". No tool read or set a task's conditions either, and `workspace_tasks` did not show them. | **Fixed.** The Mac's context is a row of a new local table, `focus_contexts`, read and written through the core, and seen by the app when the CLI changes it. New tools `workspace_conditions`, `workspace_task_conditions_set` and `workspace_context_set`; `workspace_tasks` reports `requires`. |
| 2 | High | "How many open tasks need it" counted every task that had ever required the condition — completed, archived and in archived lists — on the Mac's tab, the `cc` finder and the iPhone's sheet. | **Fixed.** The core counts open tasks only (`condition_usage`); every client reads it. |
| 3 | High | A place left on yesterday silently kept working today: tasks that needed somewhere else stayed hidden and nothing said the answer was old. Expiry was opt-in and per sitting. | **Fixed.** The context records when its conditions were set; the core calls it stale once that was on an earlier day. The status bar and the tab say so in the warning colour, and `c` clears it. |
| 4 | Medium | Nothing said what a condition was holding back. A task missing from Today could only be explained by finding it and reading its tags. | **Fixed.** Each condition in "Available now" shows how many open tasks are waiting on it; Today ends with a line naming the conditions its held-back tasks wait on, which opens the tab. `o` on a condition lists the open tasks that need it. |
| 5 | Medium | The tab's order was fixed — Location, the other categories alphabetically, Other — with conditions in creation order. Nothing could be reordered. | **Fixed.** `task_conditions.sortOrder`, kept by the core. `⌥↑`/`⌥↓` move a condition within its category, `⌥⇧↑`/`⌥⇧↓` move the whole category. |
| 6 | Medium | Renaming a category meant filing every condition in it again, one `t` at a time. | **Fixed.** `⇧T` renames the category under the cursor in one undo step; renaming onto a category in use merges the two. Location cannot be renamed away, since it is what makes a place. |
| 7 | Medium | Duplicates ("Home" and "home", "Library" made twice) could not be merged: the only way out was to re-require one on every task and archive the other. | **Fixed.** `m` merges the condition under the cursor into another: every task that needed it needs the other, the context follows, and the old one is archived. One undo step. |
| 8 | Medium | Archived conditions sat among the live ones under their categories, and a long category could not be put away. | **Fixed.** Archived conditions are a collapsed **Archived** section at the foot; `z` folds the category under the cursor (`⇧Z` folds or unfolds them all), remembered per workspace. |
| 9 | Medium | Saying where you are took the dock: `⌥⌘8`, walk to the place, `Space`, `Esc` — four or more keys, away from the work. | **Fixed.** **Say where you are…** (`gw`, palette) is a finder of the places, plus *Anywhere*: type a few letters and `Return`. |
| 10 | Low | Three names for one thing: "Available now" (Mac), "Where you are" (phones), "focus context" (code). | **Kept.** "Available now" stays the Mac's heading; the new place finder is "Say where you are…", which is what it does. The code keeps "context". |
| 11 | Low | The phones keep their own context in their own settings, and have no reordering, merging or category renaming. | **Context fixed; gestures deferred.** The iPhone and Android read and write `focus_contexts` through the core, moving the context their own settings held into it once on first launch when the workspace had none, and flag a stale context under "Where you are". The phones read the order, the open-task counts and merged requirements from the core, so nothing they show is wrong; reordering, merging and category renaming on the phones are still to come. |
| 12 | Low | A filter list cannot filter by condition ("everything that needs Campus"). | **Deferred.** It needs a new value kind in every client's rule editor; `o` in the tab and `workspace_conditions` with `condition` cover the question meanwhile. |
| 13 | Low | Making a condition whose name already exists (in any case) made a second one. | **Fixed.** Creating a condition named like a live one returns that one. |
| 14 | Low | The context is not synced: saying you are at Campus on the phone does not tell the Mac. | **Fixed.** The decision was one shared answer: you are in one place, whichever device you say it on. `v28_synced_focus_context` syncs `focus_contexts` (one row per workspace, keyed by the workspace, which every paired device shares). Every change pushes the whole row (`triggers::WHOLE_ROW_TABLES`), so the server's per-column merge keeps one device's answer rather than a mix, and the last device to write wins by the sync clock. `conditionsSetAt` travels with it, so a context said yesterday on the phone is stale on the Mac too. A device that joins brings its context into the account's workspace when that has none or its own is newer (`focus_context::adopt`). |
