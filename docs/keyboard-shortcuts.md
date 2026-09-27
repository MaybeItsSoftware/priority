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
sidebar. Text fields retain their normal macOS editing shortcuts, so a sequence
never fires while you are typing into one.

Which sequences exist is read from the catalogue per surface — there is no
second list. A letter is held only where some sequence on the current surface
begins with it, and a held letter is never lost: if the next key does not
complete a sequence, the held letter runs its own binding first and the new
key is then handled as usual (it may start a sequence of its own); if no key
follows within 1.2 seconds, the held letter runs then. So `x`, `l` and `h`
still complete, enter and leave — after the wait, or at once with Shift held,
which is the way to skip it. A hold is dropped without running when focus
moves or text editing begins, because the key no longer means what it did.

The chords that are how you leave a text field — the view and region keys,
the creation chords, `Cmd+K`, `Cmd+F`, `Cmd+/` — work from inside one; the set
is `reachableFromTextField` in the catalogue. `Cmd+Z` deliberately is not —
inside a field it belongs to the text you are typing, not to the workspace
behind it.

## Surfaces own the keyboard

Focus mode and the timeline take the main pane, and while either is up it owns
the keyboard outright. A key the screen does not answer to does not fall
through to the task surface behind it — `Delete`, a digit or `i` there used to
act on a task nobody could see. The only workspace keys that stay live are the
window's own (`reachableFromFullPaneScreens` in the catalogue): the view keys,
which leave the screen for the place you asked for, the palette, the
reference, search, undo and redo, and the sidebar, inspector and done-rail
toggles. Chords the catalogue does not know, such as `Cmd+Q` and `Cmd+W`, still
reach the app. The palette knows this: it labels each command with the surface
it belongs to and sorts the ones that apply where you are to the top.

The sidebar, the done rail and the inspector hold a cursor or controls of their
own, so the bare task keys — `Space`, `x`, `Delete`, the digits, `Tab` — do not
reach through them to the selected task. They keep the chords, `/`, `?`, `i`
and `Esc`, and the sidebar and done rail keep the two-letter sequences.

The board keeps Left/Right for column navigation, including empty columns.
Enter opens a selected task's nested board, or focuses the add-task field in an
empty column. Alt Enter and Shift Enter add above/as a child in the board too.
Escape cancels task entry and returns to navigation.

## Undo

Undo is available in Edit and in the sidebar's history menu, which names the action being undone/redone. History persists across launches and retains the latest 100 complete actions. Creating a board card, assigning its column and placing it at the top undo together; card placement and column removal also undo as complete actions. Undo/redo reveals restored work and clears selections/scopes that no longer exist. Saved edits are undoable; unsaved inspector drafts remain drafts. Completing a focus task can reopen with undo while its elapsed time and points remain recorded. Timer records stay outside edit history.
