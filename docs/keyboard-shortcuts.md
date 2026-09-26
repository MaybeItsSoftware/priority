# Desktop keyboard shortcuts

**The list of keys lives in the app, not here.** Press `Cmd+K` for the command
palette, which shows every command the workspace has and the key that runs it,
or `Cmd+/` for the same information grouped as a reference sheet. Both are
rendered from `WorkspaceCommandCatalog` (`Sources/PriorityCore/`), which is the
single place a workspace key is written down.

This file used to carry a table of its own. It is gone deliberately. There were
four copies of these facts — this table, the README's, a seventy-row literal in
the help sheet, and the `switch` in the key router that actually decided —
and nothing kept them equal. The settings pane's copy of the same problem is
[documented in `ShortcutReference`](../Sources/PriorityCore/ShortcutReference.swift):
it told people `u` was undo for months after undo moved to `Cmd+Z`. A reference
that can be wrong is worse than no reference, because it is believed.

What remains here is the behaviour a table could not express.

## Two-letter sequences

The desktop uses [Checkvist's shortcuts](https://checkvist.com/help) for
matching actions: type two letters in succession while navigating tasks or the
sidebar. A prefix expires after 1.2 seconds, and clears when focus moves or
text editing begins. Text fields retain their normal macOS editing shortcuts,
so a sequence never fires while you are typing into one.

`Cmd+K`, `Cmd+F`, `Cmd+/` and the creation chords are the exceptions: they work
from inside a text field, because each of them is how you leave that field to
do something else. `Cmd+Z` deliberately is not — inside a field it belongs to
the text you are typing, not to the workspace behind it.

## Surfaces own the keyboard

Focus mode and the timeline take the main pane, and while either is up it owns
the keyboard outright — the workspace's own single-letter keys are not live
behind them, so `Cmd+4` cannot quietly switch a board nobody can see. The
palette knows this: it labels each command with the surface it belongs to and
sorts the ones that apply where you are to the top.

The board keeps Left/Right for column navigation, including empty columns.
Enter opens a selected task's nested board, or focuses the add-task field in an
empty column. Alt Enter and Shift Enter add above/as a child in the board too.
Escape cancels task entry and returns to navigation.

## Undo

Undo is available in Edit and in the sidebar's history menu, which names the action being undone/redone. History persists across launches and retains the latest 100 complete actions. Creating a board card, assigning its column and placing it at the top undo together; card placement and column removal also undo as complete actions. Undo/redo reveals restored work and clears selections/scopes that no longer exist. Saved edits are undoable; unsaved inspector drafts remain drafts. Completing a focus task can reopen with undo while its elapsed time and points remain recorded. Timer records stay outside edit history.
