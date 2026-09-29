# Desktop keyboard shortcuts

**The list of keys lives in the app, not here.** Press `Cmd+Shift+P` (or `Cmd+K`) for the command
palette, which shows every command the workspace has and the key that runs it,
or `Cmd+/` for the same information grouped as a reference sheet. Both are
rendered from `WorkspaceCommandCatalog` (`Sources/PriorityCore/`), which is the
single place a workspace key is written down.

This file used to carry a table of its own. It is gone deliberately. There were
four copies of these facts — this table, the README's, a seventy-row literal in
the help sheet, and the `switch` in the key router that actually decided —
and nothing kept them equal. The old settings pane had the same problem: it
told people `u` was undo for months after undo moved to `Cmd+Z`. A reference
that can be wrong is worse than no reference, because it is believed.

What remains here is the behaviour a table could not express, and the format
of the file you rebind keys in.

## Zed's keys

Where Zed has a key for something Priority does, Priority uses Zed's key, so
the two apps share muscle memory. A list is treated as Zed treats a file, and
a task as Zed treats a line:

| Zed | Key | In Priority |
| --- | --- | --- |
| Command palette | `Cmd+Shift+P` | The command palette (`Cmd+K` still works) |
| File finder | `Cmd+P` | Find or create a list |
| Find in project | `Cmd+Shift+F` | Search every task (`Cmd+F` too) |
| Toggle left dock | `Cmd+B` | Show or hide the sidebar |
| Focus project panel | `Cmd+Shift+E` | Focus the sidebar |
| Toggle agent panel | `Cmd+Shift+A` | The left dock's Agent tab |
| Toggle bottom dock | `Cmd+J` | The progress graph |
| Toggle right dock | `Cmd+Alt+B` | The right dock (`Cmd+Ctrl+I` still works) |
| Close all docks | `Cmd+Alt+Y` | Put the sidebar, right dock and graph away |
| Move line up / down | `Alt+↑` / `Alt+↓` | Move the task, or the sidebar row; on Today, a planned card through the day |
| Document start / end | `Cmd+↑` / `Cmd+↓` | First / last task, or sidebar row |
| Delete line | `Cmd+Shift+K` | Delete the task |
| New file / new directory | `Cmd+N` / `Cmd+Alt+N` | New task / new folder |
| Rename | `F2` | Rename the task, or the sidebar row |
| Undo / redo | `Cmd+Z` / `Cmd+Shift+Z` | Undo / redo |
| Settings | `Cmd+,` | Preferences |

The sidebar is Zed's project panel, with a list as a file and a folder as a
directory. Its keys act on the sidebar row, never on a task behind it:

| Zed project panel | Key | In Priority's sidebar |
| --- | --- | --- |
| New file | `Cmd+N`, `%` (vim) | New list, beside the row you are on |
| New directory | `Cmd+Alt+N`, `d` (vim) | New folder, beside the row you are on |
| Rename | `F2`, `Shift+R` (vim) | Rename the list or folder |
| Trash / delete | `Delete`, `Cmd+Delete`, `Shift+D` (vim) | Delete the list or folder (it asks) |
| Collapse / expand all | `Cmd+←` / `Cmd+→` | Every folder |
| Collapse / expand | `←` `h` / `→` `l` | The folder; ← and `h` go up a level from a list |
| Select parent | `-` (vim) | Up a level |
| Open | `Space`, `Return` | Open the row |
| First / last | `gg` / `Shift+G` (vim) | The sidebar's ends |
| Previous / next directory | `{` / `}` (vim) | The previous / next folder |
| Command palette | `:` (vim) | The palette |

Because the sidebar has its own `d`, `h` and `l`, it does not hold them for
the task sequences that begin with them (`dd`, `hc`, `ll`): a letter a surface
binds on its own runs at once there. And Shift on a letter is a key of its
own — `Shift+D` is not `d` — though a `Shift` letter nothing binds still runs
the plain letter, so `Shift+X` remains the way to skip a sequence's wait.

Taking those keys moved what Priority had on them: archiving a list is
`Cmd+Alt+A` (was `Cmd+Shift+A`), promoting a nested list `Cmd+Alt+P` (was
`Cmd+Shift+P`), renaming a task by chord `Cmd+Ctrl+E` (was `Cmd+Shift+E`), and
moving a task or sidebar row `Alt+↑`/`Alt+↓` (was `Cmd+↑`/`Cmd+↓`).

Zed's two-chord sequences, such as `Cmd+K Cmd+S` for the keymap, are not
supported: `Cmd+K` is the palette here. **Open the keymap file** is in the
palette instead. Zed keys with nothing to act on in a task app — go to line,
multi-cursor, toggle comment, the terminal — are left unbound.

## Your own keys: `keymap.json`

The window's keys can be rebound in
`~/Library/Application Support/Priority/keymap.json`. **Open the keymap
file** in the command palette creates it (as `[]`, an empty keymap) and opens
it in your editor. It is re-read when you save it and whenever Priority comes
to the front; **Reload the keymap** forces it. The palette, the reference, the
tooltips and the menu bar all show the keys in force, so a rebound key's key
cap moves with it.

The shape is Zed's: an array of blocks, each with an optional `context` and a
`bindings` object from key to command id. `null` unbinds.

```json
[
  { "bindings": { "cmd+shift+k": "taskComplete", "gg": null } },
  { "context": "board", "bindings": { "x": "taskDelete", "delete": null } }
]
```

- **Command ids** are the cases of `WorkspaceCommandID`
  (`Sources/PriorityCore/WorkspaceCommandID.swift`) — `taskComplete`,
  `goBoard`, `listRename` and so on.
- **Keys** are written the way the catalogue writes them: modifiers `cmd`,
  `ctrl`, `option`, `shift` joined to the key with `+` (Zed's `-` works too,
  and so do `command`, `alt`, `return`, `esc` and `backspace`). Named keys are
  `enter`, `escape`, `tab`, `space`, `delete`, `up`/`down`/`left`/`right`,
  `home`, `end`, `pageup`, `pagedown`, `f2` and `comma`. Two plain letters,
  such as `gt`, make a two-letter sequence. Shift on a lone character is
  already in the character: write `?`, not `shift+/`. A letter is the
  exception — `shift+d` is a key of its own, as in Zed.
- **Without a `context`** a binding applies wherever the command does. The key
  is added to the command's own keys — the defaults stay — and taken from any
  other command that had it on the same surface. A `null` there removes the
  key from every command.
- **With a `context`** it applies on that surface only: `today`, `board`,
  `outline`, `matrix`, `sidebar`, `inspector`, `focus`, `focusRunning`,
  `timeline` or `done`. A `null` there stops the key meaning anything on that
  surface unless the same file gives it a new job there. A command that
  belongs to one surface — the focus ladder's, the timeline's — can only be
  bound in its own context.
- Within a block the `null`s apply first, so unbinding a key and binding it
  again can be written in either order. Blocks apply top to bottom.

Mistakes are reported, never fatal. An unknown command id, a key no key press
can produce, an unknown context, or one key bound twice on the same surface is
a line in **Diagnostics → Recent problems** and a message on the window; the
rest of the file still applies, and a file that is not JSON at all leaves the
defaults in force. The few commands that act on *which* key ran them — the
priority digits, the direction keys, `⌥1`–`⌥4` on the matrix — cannot be
bound to another key, though their keys can be unbound.

The three global hotkeys (show the window, the focus panel, quick add) work
outside the window and are set in **Preferences → Keybindings** instead.

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
the creation chords, the palette, search, `Cmd+/`, and the agent panel's toggle for the agent
panel — work from inside one; the set is `reachableFromTextField` in the
catalogue. `Cmd+Z` deliberately is not — inside a field it belongs to the text
you are typing, not to the workspace behind it.

The agent panel counts as a field as a whole while it holds the keyboard, its
approval cards included: Return on a focused card approves that card, and must
not fall through to open the task selected behind it. See
[`agent-panel.md`](agent-panel.md).

## Surfaces own the keyboard

Focus mode and the timeline take the main pane, and while either is up it owns
the keyboard outright. A key the screen does not answer to does not fall
through to the task surface behind it — `Delete`, a digit or `i` there used to
act on a task nobody could see. The only workspace keys that stay live are the
window's own (`reachableFromFullPaneScreens` in the catalogue): the view keys,
which leave the screen for the place you asked for, the palette, the
reference, search, undo and redo, and the sidebar, agent, inspector and
done-rail toggles. Chords the catalogue does not know, such as `Cmd+Q` and `Cmd+W`, still
reach the app. The palette knows this: it labels each command with the surface
it belongs to and sorts the ones that apply where you are to the top.

The sidebar, the done rail and the inspector hold a cursor or controls of their
own, so the bare task keys — `Space`, `x`, `Delete`, the digits, `Tab` — do not
reach through them to the selected task. They keep the chords, `/`, `?`, `i`
and `Esc`, and the sidebar and done rail keep the two-letter sequences.

## Return and Shift-Return

They mean the same thing on every task surface:

- **Return opens the task you are on.** On Today that is starting its card —
  a task on the day *is* a block to run — and, on the card that is running,
  finishing it. On the board, the outline and the matrix it opens the task's
  subtasks as a board of their own. With nothing selected — an empty column,
  an empty list — Return adds a task instead, so it is never dead.
- **Shift-Return ticks the task off** without running a block, as Space and
  `x` do.
- Adding is `Cmd+N` (below the selected task in the outline and the matrix),
  `Option+Return` (above it) and `Option+Shift+Return` (a subtask).

The outline used to add a task on Return and a subtask on Shift-Return, while
Today started and ticked. One key meaning two things depending on the pane is
exactly what a keyboard-first app cannot afford, and Today's meaning is the one
a Blitzit-style day is built on.

The board keeps Left/Right for column navigation, including empty columns.
Up/Down walk a column row by row, and a card's subtask rows are rows: the
keys step onto each subtask the card is showing before the next card, and
over a folded card's tree without stopping. Left/Right from a subtask leave
from the column its card is in.
Escape cancels task entry and returns to navigation.

## Planning the day

`Ctrl+T` puts the selected task on today — the Today board column — or takes
it off, from any task surface, and the status bar says which it did. It is not
`Cmd+T`, which sets the due date to today: a date is a fact about the task, a
plan is a choice about the day, and Today treats them differently.

On Today, `Alt+↑` / `Alt+↓` stop meaning "move among siblings", because the
day's cards come from every list and are siblings of nothing. They move the
card through the planned part of the day instead, and the whole planned order
is written at once (one undo step, "Reorder Today"), so it holds when some
other task's urgency changes. Only planned cards move. An overdue, due-today
or starting-today card is in the day because of its date and stays where the
date puts it; pressing `Alt+↓` on one leaves it and tells you to plan it first
with `Ctrl+T`, after which it is yours to arrange. The running block heads the
day whatever it is, and does not move either.

## Typing a task

Whatever adds a task reads the end of what you typed: `30m` or `1h30m` sets
the estimate, `@fri`, `@tomorrow`, `@3d` or `@2026-10-02` the due day, `#work`
a tag and `!1`–`!4` the priority. So `Write notes 45m #work @fri !1` is one
Return, not a Return and four edits. Only trailing words count, and the first
one from the end that is not a token stops the reading, so `Read 30 pages`
keeps its `30`; the first word is always the title's. The title bar's field
and the focus panel's "Add … to today" row show what they found as chips
before you press Return. The full table is in the README, under
[Typing a task](../README.md#typing-a-task).

## Undo

Undo is available in Edit and in the sidebar's history menu, which names the action being undone/redone. History persists across launches and retains the latest 100 complete actions. Creating a board card, assigning its column and placing it at the top undo together; card placement and column removal also undo as complete actions. Undo/redo reveals restored work and clears selections/scopes that no longer exist. Saved edits are undoable; unsaved inspector drafts remain drafts. Completing a focus task can reopen with undo while its elapsed time and points remain recorded. Timer records stay outside edit history.
