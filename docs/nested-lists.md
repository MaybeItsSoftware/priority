# Folders, lists, and tasks

Folders organise standalone lists. Lists can contain tasks and nested lists;
tasks can also keep subtasks without automatically becoming lists.

Nested lists use an explicit kind on the existing task-tree record. Converting
between task and list keeps the record ID, parent, children, notes, dates,
estimates, import identity, and metadata. No existing task is inferred to be a
list just because it has children or a broad title.

Promotion pins a sidebar shortcut; it does not reparent or copy a list. Nested
lists remain visible under their owning list, and can be moved by dragging
onto another nested list. Existing folder settings organise standalone lists.

Tasks, nested lists, and standalone sidebar lists can be dragged onto any
sidebar list or nested-list card. A standalone list becomes a nested list with
its contents retained; a nested item keeps its ID and complete subtree. Drops
onto ordinary task cards still reorder sibling tasks. Dragging a nested item
onto its own standalone list moves it back to the visible root. Self/descendant
drops are rejected, and Inbox cannot be nested. All hierarchy moves are undoable.
`M` opens the same destination choices in a keyboard-navigable picker, including
nested destinations and destinations within the current standalone list.

The sidebar shows Everything, then Inbox, then the Lists section. Drop a
nested list onto the Lists heading to extract it as a standalone top level
list, or use its “Move to top level” context menu action. Its descendants and
identity are retained, and undo restores its original parent. Standalone lists
can also be dropped on this heading to move them out of a folder.

Folder rows also accept drops and appear in the `M` destination picker.
Standalone lists change folders directly. A nested list becomes a standalone
list inside the folder, with its root record and descendants retained. An
ordinary task likewise becomes its own top-level list named after the task,
with its subtasks as the list contents. Conversion and relocation are one
undo step; undo restores the original task and hierarchy.

Lists have icons rather than completion checkboxes. Their context menus and
inspector offer explicit completion/reopening, promotion, conversion, icon
selection, and archiving. Completed lists remain available for review;
archived lists can be restored using the sidebar archive menu. Completing or
archiving a list leaves its children's individual statuses untouched, but
excludes the contents from Everything and automatic focus suggestions.

Converting a standalone sidebar list to a task places it in Inbox with all its
contents as subtasks. An imported visible-root wrapper is reused if present.
This operation, like nested conversion and promotion, is one undoable step.

Keyboard controls:

- `]` / `[` — enter the selected item's contents / return to its parent.
- `Command-Shift-L` — convert selected task/list; on a standalone sidebar list,
  convert it into an Inbox task.
- `Command-Shift-P` — promote/unpin the selected nested list.
- `Command-Shift-N` — create a nested list in the task pane, or a standalone
  sidebar list when navigating the sidebar.
- `Command-Shift-X` — complete/reopen the current list.
- `Command-Shift-A` — archive the current list.
- `Command-R` — rename the sidebar selection.
- `Command-I` — settings for the sidebar selection, including icon choice.

Native task focus outlines stay disabled; navigation uses the app's rounded
selection highlight. Left from Backlog returns to the current list's sidebar
row, revealing its folder if needed.

Schema migration `v14_nested_lists` is additive, with nullable columns so old
undo snapshots and pre-existing task records remain compatible. Icons continue
to use the existing local app preference store.
