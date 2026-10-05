# Task organisation and editing fix plan

Status: implemented, with manual UI verification pending, 16 September 2026.

Based on [the audit](task-organisation-audit.md). This covers all four remaining
findings, recovery for older renamed imported wrappers, and verification of the
fixes already implemented.

## Implemented editing behaviour

- Keep explicit Save, Return in the title field, and Cmd+S. Show when there are
  unsaved changes and provide Revert to discard the current draft deliberately.
- Retain drafts by workspace and task identity when selection changes, the
  inspector closes, a task moves, or the app closes. Restore them on reopening.
- Saving applies all changes together and produces one undo step. A failed
  save preserves the draft and leaves saved data unchanged.
- Undo/redo immediately refreshes an editor with no unsaved changes. For a
  dirty editor, preserve the user's edits and reconcile them with saved changes.
  If both changed the same field differently, require a choice between the
  saved value and the draft value before saving that field.
- Settings sheets close after a successful Save or explicit Cancel. Errors
  stay with the open form and its entered values.

These are the implemented product defaults. Draft retention
allows normal navigation without a confirmation prompt on every task change.

## Implementation status

| Step | Status |
| --- | --- |
| Atomic editor saves and valid destinations | Implemented in `WorkspaceStore+Editing.swift`; forms dismiss only on successful commits. |
| Draft retention | Implemented with an observable manager in `Takt/Editing/WorkspaceTaskEditor.swift` and separate atomic local storage. |
| Undo/redo reconciliation | Implemented per field, with explicit conflict choices and stale-save rejection inside the transaction. |
| Legacy root recovery | Implemented in list settings, with a preview and one undoable settings Save. |
| Automated verification | 1,037 tests passed, including injected rollback failures and restoration after deletion. Final Debug and Release app builds passed. |
| Interactive verification | Pending; this session has no GUI automation tool. Focus, gesture and keyboard checks below remain the manual checklist. |

Untouched estimates preserve exact stored seconds. Edited estimates accept
non-negative fractional minutes and round to the nearest second; invalid and
out-of-range input stays in the draft and cannot silently clear the estimate.

## 1. Make task, list and folder saves atomic

Implement this first because editor state needs a reliable save result.

Add complete edit requests and store methods in
`Sources/TaktWorkspace/WorkspaceStore+Editing.swift`:

- Task: title, notes, due date, estimate, editor metadata and daily attachment.
- List: name, colour, folder and archive state.
- Folder: name and parent folder.

Extract database helpers from existing mutations so a complete edit uses one
`journalledWrite` and one database transaction. Helpers take the existing
`Database`; do not call public methods that start their own transactions from
inside another write. Keep existing single-action methods using those helpers.

Validate the complete request against current records before writing: required
names, record existence, destination workspace, folder ancestry and the Inbox's
permanent role. Validate estimate input and multiplication bounds; preserve the
stored estimate exactly when that field was not edited. Use the newly saved
estimate when enabling a daily, while retaining existing daily schedule,
identity and contributions.

Compare editable values before updating timestamps or creating metadata.
Unchanged Saves must preserve undo/redo. Preserve task status, hierarchy, source
identity, board/matrix placement and metadata outside the editor's fields.

Return an explicit save result and the committed editor snapshot. Update
`WorkspaceViewModel` and its sidebar/dailies extensions to call one store method
per Save, then refresh affected projections once. Separate a committed save
from a subsequent display-refresh failure so users are not asked to repeat an
already committed operation.

In `WorkspaceInspectorViews.swift`, dismiss settings only on success. Disable
Inbox archive/delete controls. Filter a folder and all its descendants from
the parent picker, using a shared hierarchy query; retain store validation for
destinations that become invalid after the form opens.

**Acceptance:** a combined folder rename and invalid move changes nothing; a
task Save involving metadata and a daily undoes/redoes completely with one
command; unchanged Save does not alter history; failed Save keeps the form open.

## 2. Move task drafts out of the inspector's view lifecycle

Add Foundation-only editor snapshot, draft and validation types to
`TaktWorkspace`, with tests in `workspace-tests`. Add an observable draft
manager under `Takt/` and keep `LocalTaskInspector` focused on bindings and
focus behaviour. The app's synchronised source group will include app files;
package types and tests use the existing workspace targets.

Each draft contains its workspace/task identity, the saved baseline, current
field values and dirty fields. Include metadata and daily state in the baseline,
not just the task row. Preserve raw input such as an incomplete estimate while
the user is typing; validate it at Save rather than silently clearing a value.

Store drafts locally outside the task undo journal, with versioned encoding
and atomic writes. Debounce writes while typing and flush on navigation and
normal shutdown. Saving or Revert removes the draft. Storage failures leave
the draft available in memory and must not imply that it was persisted.

Switching selection selects the corresponding draft instead of resetting
`@State` from `loadTask()`. Moving a task retains its draft under the same
identity. If deletion or undo removes its task, retain the draft as unavailable
for restoration, disable Save and never recreate the task implicitly. Reconcile
retained drafts when the task returns through undo/redo.

**Acceptance:** edit A, visit B, return to A, close/reopen the inspector and
restart the app: A's draft is retained. Save/Revert clears it. Invalid input and
save errors do not discard it. A's fields never appear in B's editor.

## 3. Reconcile drafts after undo, redo and stored edits

Replace the inspector's `task.id`-only refresh with explicit editor snapshot
refresh after relevant successful mutations and history actions. Read task
content, metadata and daily state consistently from the store. Update
`WorkspaceViewModel+History.swift` to notify the draft manager after applying
history and resolving deleted selections.

Use the baseline, draft and current saved snapshot to reconcile each field:

| Situation | Behaviour |
| --- | --- |
| Field has no draft edit | Adopt its current saved value. |
| Only the draft changed | Preserve the draft edit. |
| Both now contain the same value | Mark the field reconciled and clean. |
| Saved value and draft changed differently | Keep both values and show a conflict choice. |

Advance the baseline after reconciliation. Compare it again inside the Save
transaction; a stale request returns a conflict without partial writes. This
prevents a delayed refresh from allowing stale fields to overwrite newer data.

Keep text-field Cmd+Z under native text editing. Workspace undo applies once
focus leaves text editing. Reconciliation must not unexpectedly move keyboard
focus or select text, and resolving a conflict is not itself a task undo step.

**Acceptance:** Save a rename, leave the text field and undo: the open inspector
shows the restored title. Metadata-only and daily changes also refresh. Dirty
notes survive an unrelated saved-title change; competing title changes cannot
silently overwrite each other. Redo and deletion/restoration behave consistently.

## 4. Provide explicit recovery for older imported wrappers

Keep the migration's conservative inference. Add a list-settings action to
select an imported top-level wrapper whose children should form the visible
list root, plus an action to show the actual root hierarchy again.

Validate that the selected task belongs to the list, is its sole top-level
root, is imported and has children. Persist `visibleRootTaskId` through a
journalled store method. Changing this setting must not rename or move tasks.
Give the action a visible explanation and preview of the resulting root tasks.

**Acceptance:** an older imported list with different list/wrapper names can
recover its visible children without renaming either record. Recovery survives
reopen and undo/redo. Invalid candidates are rejected without hiding work.

## 5. Complete regression and interactive verification

Add meaningful tests alongside each implementation step:

- Transaction rollback, complete undo/redo, no-op history, existing daily
  preservation, fresh estimate use, missing records and stale edit conflicts.
- Self/descendant/cross-workspace folder rejection and valid destination lists.
- Draft retention, persistence, Revert, reconciliation and deleted-task recovery.
- Legacy wrapper recovery without changes to task placement or titles.

Use temporary workspace fixtures for tests and the manual UI pass. Verify
Return, Escape, click-away and consecutive sidebar renames; double-click word
selection within rename fields; Cmd+Up/Down in each focused region; inspector
Save failure and selection changes; task moves while editing; and undo/redo
while the inspector stays open. Repeat these in Inbox, ordinary lists, imported
lists, Everything and scoped projects where applicable.

Check title renames leave unrelated task fields intact, including estimates
that are not whole minutes. Verify board, outline, matrix, Dailies and focus
projections update after editor commits and history changes.

Run the complete Swift suite, SwiftLint and Debug/Release app builds after the
integrated changes. Record manual outcomes and update the audit with resolved
findings and any remaining limitations.

**Done means:** all audit findings have a verified resolution; navigation loses
no drafts; each Save is atomic and one undo step; history cannot silently reapply
stale editor values; invalid folder moves are prevented; legacy root recovery is
available; and the previously fixed rename/organisation gestures pass the UI check.

## Suggested implementation sequence

1. Atomic editor store APIs, validation and settings wiring.
2. Task draft types, persistence and inspector bindings.
3. History refresh, field reconciliation and conflict handling.
4. Legacy wrapper recovery controls and store method.
5. Integrated UI verification and audit update.

Each step should include its tests and remain independently reviewable. This
plan does not require another schema migration if drafts use separate local
storage and recovery uses the existing visible-root identity column.
