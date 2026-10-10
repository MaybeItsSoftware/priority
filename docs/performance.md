# Switching

How the desktop window changes what it shows — a list to the next,
Everything, a folder, Today, the outline, board and matrix, the palette, the
inspector — without making you wait. The model is Zed's: what you have looked
at stays in memory, a switch changes what is drawn rather than what is read,
and anything that does have to be read again is read off the main thread.

## What is resident

`WorkspaceScopeCache` (`Sources/TaktWorkspace/WorkspaceScopeSnapshot.swift`)
holds the scopes the main pane has shown lately, eight of them, least recently
used first out. A scope is `.list(id)` or `.combined(listIDs)` (Everything, a
folder). Each entry is:

- the scope's one read (`WorkspaceScopeRead`): a list's whole tree with every
  task's column and matrix place, or a combined scope's board as the core
  walks it;
- the `WorkspaceChangeStamp` it was read at;
- the outline and board shaped from it (`WorkspaceScopeShaping`), per shape
  options (the entered task, the list's wrapper root, whether finished work is
  hidden), each numbered so the view model can key what it derives from them.

On top of that the view model keeps, per board shape, the indexes it builds
for the views: the columns' cards, the matrix's quadrants, the arrow keys' row
index and the board's links (`BoardIndexMemo`, keyed by the shape's number,
the columns and the folds). Going back to a board drawn before assigns these
rather than sorting thousands of cards again.

Two more reads used to be made on every switch and are now keyed to the
stamp: the done rail's rows (`reloadCompleted`), which cover every list and
so cannot change on a switch, and the waiting chips (already were).

## When it is dropped

Nothing is invalidated by a switch. An entry is current while the store's
`changeStamp()` equals the one it was read at; the stamp moves on any commit,
the app's own (`ownChanges`) or another process's (`data_version`). So:

- **No write since**: going back to the scope reads nothing and shapes
  nothing — a stamp read and dictionary lookups.
- **A write since, then a switch**: a list is read again on the main thread,
  because one list is cheap (about 1 ms) and its read compares cheaply, so an
  unchanged list keeps its shapes. A combined scope is drawn as kept, in the
  same frame, and read again in the background; if the answer differs it is
  shaped there too and swapped in, and if not the entry is simply re-stamped.
- **A write in the scope on screen** (`perform`): the scope is read again on
  the main thread before the refresh ends, as before. What you just did has to
  be on screen, and code that reads the result on the next line relies on it.
- A shape with a finished task still lingering on it (the few seconds after a
  tick) is kept only until that task's time is up.

## What runs off the main thread

- The background reread of a kept combined scope, its comparison with what is
  held, and its shaping (`revalidateScope`).
- Reading ahead: after every switch the lists either side of the new one in
  the sidebar (and the first list, from Everything) are read in the
  background (`prefetchAdjacentScopes`), so the next ↑ or ↓ finds them
  resident. These are held apart from the scopes in use, two at most, so a
  guess never pushes out somewhere you have been.
- Both read on a second handle on the file (`WorkspaceStore.backgroundCore()`,
  `scopeRead(_:hidingCompletedBefore:inBackground:)`). The store's own handle
  serialises every call on one connection, so a background read made there
  was a read a keystroke's write waited behind.
- Next up, as before (`WorkspaceNextUpSnapshot`).

## What is laid out

Every long surface is lazy: the outline is a `List`, the board's columns a
`LazyHStack` of `LazyVStack`s, the sidebar, the done rail, the palette and the
navigators `LazyVStack`s. The matrix's unplaced section was an eager `VStack`,
which in Everything laid out every unplaced card (six and a half thousand on
the benchmark workspace) on the switch; it is a `LazyVStack` now. The four
quadrants are still eager, sized by a `Grid`; see below.

## Measuring

    TAKT_PERF=1 swift test -c release --filter WorkspaceSwitchingBenchmarks

runs `workspace-tests/WorkspaceSwitchingBenchmarks.swift` on the seeded
7,000-task workspace of `WorkspacePerformanceBenchmarks`. A switch's work is
on the main thread, so the time until the new content is ready and the time
the main thread is blocked are the same number, except where a column says
otherwise. These are the view model's reads, shapes and indexes, not SwiftUI's
layout: for that, record the `Switching` category of
`uk.co.maybeitssoftware.takt` in Instruments' os_signpost instrument. Each
switch is an interval named for it (`Select list`, `Select Everything`,
`Select folder`, `Select view mode`, `Enter task`, `Leave task`), with a
`Switch to next turn` interval ending once the run loop has gone round, and an
event when a background reread swapped a changed scope in.

Measured 2026-10-10, release build, median of 7–9 runs, in milliseconds:

| Switch | Before | After, resident | After, kept but written since |
|---|---:|---:|---:|
| list → list (board) | 1.45 | 0.13 | 1.14 (one list read again) |
| list → list (outline, the inbox) | 0.83 | 0.11 | — |
| → Everything (board) | 42.6 | 1.07 | 1.23, then 33.7 off the main thread; 9.4 to swap in if it changed |
| → a folder (board) | 7.4 | 0.19 | as Everything, smaller |
| → Today | 0.02 | 0.02 | — |
| Everything, board → outline | 25.0 | 3.2 | — |
| Everything, outline → board | 43.7 | 1.07 | — |
| one list, outline ↔ board ↔ matrix | no read before or after | | |
| command palette opens | 0.02 | 0.02 | |
| inspector opens (editor snapshot) | 0.03 | 0.03 | |
| done rail open, per switch | +3.4 | +0 | +3.4 once |
| a write on the main thread while a background read of Everything runs | — | 11.5 on the store's own handle | 0.25 on the background handle |

"Before" is every switch reading its scope again, which is what the first
visit to a scope still costs. The benchmarks in
`WorkspacePerformanceBenchmarks` are unchanged by this work.

## Not done

- A write's own refresh of a combined scope is still read and shaped on the
  main thread (about 45 ms for Everything's board). Moving it off would mean
  every caller that reads the outline or board straight after a write waiting
  for it instead.
- The matrix's quadrants are eager; a quadrant holding thousands of placed
  cards would lay them all out. The benchmark workspace places 480.
- The list settings inspector reads its root candidates from the store in its
  body; small, and only while it is open.
