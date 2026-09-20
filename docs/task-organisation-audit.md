# Task organisation and renaming audit

16 September 2026. Scope: the desktop workspace's sidebar, task editing,
hierarchy moves, board roots and undo. This is a source audit with database
regression tests and an app build; interactive UI reproduction has not been run.

## Follow-up implementation

All four remaining source findings below now have implementations:

- The inspector binds to drafts retained by task identity, with an unsaved
  indicator, Save and Revert. Dirty drafts survive selection changes and
  restart using separate versioned local storage.
- Clean editors refresh after saved edits and history actions. Dirty fields
  reconcile against the latest saved snapshot; conflicting fields offer
  "Use saved" and "Keep my edit". Save checks the baseline again inside the
  database transaction, preventing stale requests from overwriting newer data.
- Task content, metadata and daily attachment save in one transaction and one
  undo group. List and folder settings also save together. Failed forms retain
  their entered values and stay open; unchanged Saves preserve redo.
- The parent-folder picker excludes the folder itself and all descendants;
  transaction validation also rejects invalid or cross-workspace destinations.

List settings additionally provide explicit recovery for imported wrappers
whose names no longer match their lists. The visible-root selection includes a
preview and is undoable without moving or renaming tasks. Existing estimates,
daily schedules and contribution history survive unrelated edits.

Automated verification covers these changes; native focus and gesture behaviour
still needs the manual UI pass in [the implementation plan](task-organisation-fix-plan.md).

## Fixed in this audit

| Problem | Result after the fix |
| --- | --- |
| Renaming a list or its imported wrapper changed which tasks appeared at the top. | Imported wrappers are recorded by task identity at import or migration. Renaming either record keeps the visible structure, including after reopening and undo. |
| A normal task sharing its list's name could disappear from boards and Everything. | Wrapper recognition applies to imported trees with children. Ordinary tasks stay visible. Recognition retains Unicode letters and rejects empty normalised names. |
| Moving work into an imported list created another root and disrupted its board. | Sidebar and inspector moves place the whole subtree beside the destination's visible tasks, in one undo step. |
| Renaming a list released by folder deletion could reorder the sidebar. | Lists and folders use creation time and identity to break order ties, rather than their editable names. Reordering uses the same order. |
| Cmd+Up/Down could move the backing list when a folder was selected, or a task when the sidebar had focus. | Reordering follows the focused region and prefers its selected folder or list. |
| Return/Escape and focus loss could finish the same rename twice; an old rename could cancel the next one. | Rename fields finish once. Escape marks the edit cancelled before teardown; callbacks clear only their own rename session. Folder rename fields are no longer nested inside buttons. |
| Reordering at a boundary cleared redo despite changing nothing. | Only recorded changes invalidate redo. Filing something where it already lives and unchanged sidebar renames also do nothing. |
| Creating a list from inside a project, archiving the current list, or moving the scoped project could leave a stale scope. | List creation resets selection through normal navigation; replacement lists reset task scope, and moved scopes return to the source list root. Deleted folder selections are cleared. |

The additive `v11_stable_visible_roots` migration records recognisable existing
imported wrappers and updates older list undo snapshots. Already-renamed legacy
wrappers whose titles no longer match their lists cannot be inferred reliably;
they retain their actual, fully visible hierarchy.

## Original remaining findings, now addressed

1. **Task editor drafts can be silently discarded.** Edit a title or notes,
   then select another task or close the inspector before Save. The editor
   reloads from the task and has no draft retention or leave handling.
   See [WorkspaceInspectorViews.swift](../Priority/WorkspaceInspectorViews.swift).
   Decide whether to save automatically or retain drafts by task identity.

2. **Undo can leave the inspector showing stale values for the same task.**
   Save a rename, move focus out of the text field, then undo while leaving
   the inspector open. Its reload observes `task.id`, which has not changed,
   rather than changes to the saved content. Saving again can reapply the
   stale values. Refresh clean editors when stored content or history changes,
   with explicit handling for dirty drafts.

3. **One Save spans several transactions and undo steps.** Task content,
   metadata and daily attachment are saved separately. List settings save
   name/colour, folder and archive state separately; folder settings save
   name before attempting the move. A later failure can leave earlier edits
   committed, and the sheets dismiss regardless. Make each editor Save one
   validated transaction and one undo group, and dismiss only on success.
   See [WorkspaceViewModel.swift](../Priority/WorkspaceViewModel.swift) and
   [WorkspaceInspectorViews.swift](../Priority/WorkspaceInspectorViews.swift).

4. **Folder settings offer invalid destinations.** A folder's descendants
   appear in its parent picker. Choosing one fails the store's cycle check
   after the rename may already have committed. Filter descendants from the
   picker and validate the complete edit before writing.

## Initial audit verification

- Full Swift package suite: 1,005 tests passed before the final ordering fix.
- Final workspace suite: 81 tests passed, including eight new organisation
  regressions and an additional migration/old-undo-snapshot regression.
- Debug app build with signing disabled passed; final incremental verification
  also checks the last sidebar ordering change.
- Database tests use temporary fixtures and cover reopen, subtree moves,
  promotion, deletion/restoration, rename stability and no-op redo retention.
- Focus transitions, double-clicks and keyboard gestures still need a manual
  UI pass. The remaining editor findings are supported by source inspection.

## Follow-up verification

- Full Swift package suite: 1,037 tests passed with no failures on
  16 September 2026. This includes 31 new database, draft and observable
  editor-manager tests for the follow-up fixes.
- Regression coverage includes transaction rollback after a late failure,
  preservation of redo after failed or unchanged saves, stale-save rejection,
  field conflicts, selection changes, restart recovery, deletion/restoration,
  invalid folder destinations and legacy-wrapper recovery.
- SwiftLint passed with no serious violations; four size warnings remain in
  the existing workspace view-model and store files.
- Final Debug and Release macOS app builds passed with code signing disabled.
- Interactive focus, gesture and keyboard checks remain pending in the plan;
  this session has no GUI automation tool.
