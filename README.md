<img src="Priority/Assets.xcassets/AppIcon.appiconset/ios-1024.png" alt="" width="72" align="left" />

# Priority

**A keyboard-first macOS desktop app for working your task lists fast.**
Quick navigation, priority and due workflows, focus timers, a kanban board, an honest daily log, and a command line that reaches the same data.

<br clear="left" />

---

Priority opens as a desktop window, keeps a menu bar surface for quick capture, and is built to be driven without the mouse. Its own local workspace owns your tasks; Checkvist is an optional import. Priority adds the things a plain list has no representation for — priority ranking, start dates, recurrence, focus sessions, daily habits, and a record of what actually happened each day.

It works offline. It works from the terminal. And it exposes the whole surface to an AI assistant over MCP.

- **macOS 15.6+**
- Repository: [MaybeItsSoftware/priority](https://github.com/MaybeItsSoftware/priority)

## Contents

- [Install](#install) · [First run](#first-run)
- [Keyboard flow](#keyboard-flow) · [Focus](#focus) · [Command palette](#command-palette)
- [Views](#views) · [The menu bar](#the-menu-bar) · [The window](#the-window) · [Themes](#themes) · [Diagnostics](#diagnostics)
- [Daily log](#daily-log) · [Obsidian daily notes](#obsidian-daily-notes) · [AFFiNE](#affine)
- [Command line](#command-line) · [MCP server](#mcp-server) · [Plugins](#plugins)
- [Build from source](#build-from-source) · [Where your data lives](#where-your-data-lives)

## Install

1. Download the latest `.dmg` from [Releases](https://github.com/MaybeItsSoftware/priority/releases).
2. Drag `Priority.app` into `Applications`.
3. Right-click it once and choose **Open**.

The build is signed with a development certificate rather than a Developer ID, so Gatekeeper will ask the first time. If it refuses outright:

```bash
xattr -cr /Applications/Priority.app
```

Or build it yourself — see [Build from source](#build-from-source).

## First run

Open Preferences with `Cmd+,`:

| Step | What |
| --- | --- |
| 1 | Checkvist username and remote API key (from [checkvist.com/auth/profile](https://checkvist.com/auth/profile)) |
| 2 | The checklist/list ID to work in |
| 3 | Global hotkey to show the window |
| 4 | Focus panel hotkey — `⌃⌥⇧⌘F` by default |
| 5 | Quick-add hotkey, and whether it targets the list root or a specific parent |
| 6 | Day rollover hour — when your day starts, default 04:00 |
| 7 | Obsidian inbox folder *(optional)* |
| 8 | MCP integration *(optional)* |
| 9 | Launch at login |

None of it is required: the workspace is local-first and works with every row
left blank. Checkvist, Obsidian and Google Calendar are set up from their own
pages under **Preferences → Plugins**, when you want them.

## Keyboard flow

The window is keyboard-first: every mode, every surface and every task action
has a key. The mode strip names the modes, and the View, Task and Workspace
menus list what you can do with the key beside each item — every task action
is in the Task menu, and the ones whose key is a two-letter sequence have a
chord as well so the menu can show one. So none of it is reachable only by
something you already have to know.

| Key | Action |
| --- | --- |
| `Cmd+1`–`Cmd+4` | Today, Board, Outline, Matrix |
| `Cmd+8` / `Cmd+9` | Focus / Timeline — both take the main pane |
| `Cmd+0` | Everything, across all active lists |
| `Ctrl+1` / `Ctrl+2` / `Ctrl+3` | Focus the sidebar, the task surface, the inspector |
| `Cmd+B` | Show or hide the sidebar (Zed's left dock) |
| `j` / `k` / `↑` / `↓` | Move the selection |
| `Cmd+↑` / `Cmd+↓` | First / last task |
| `Alt+↑` / `Alt+↓` | Move the task up / down (Zed's move line) — on Today, earlier or later in the day |
| `Alt+←` / `Alt+→` | Outdent / indent the task — out of, or under, the task above |
| `Shift+Alt+←` / `Shift+Alt+→` | Move the card a board column left / right |
| `Shift+Alt+↑` / `Shift+Alt+↓` | Move the task to the list above / below in the sidebar (`mm` picks any list) |
| `Ctrl+T` | Plan the task for today, or take it off |
| `Cmd+Shift+K` | Delete the task (Zed's delete line) |
| `Return` | Open the task you are on — on Today, start its card (or finish the one running); elsewhere, open its subtasks. With nothing selected, add a task |
| `→` / `←` | In the outline, show a task's subtasks and step into them / hide them and step out — without opening the task. Elsewhere, open and leave it |
| `za` / `Cmd+←` / `Cmd+→` | Fold or unfold the task you are on (outline or board) / fold / unfold the whole outline |
| `Shift+Return` / `Space` | Tick the task off without running a block |
| `Cmd+N` / `Cmd+Shift+N` / `Cmd+Alt+N` | New task / list / folder |
| `Alt+Return` / `Alt+Shift+Return` | New task above the selection / new subtask |
| `Cmd+F` / `Cmd+Shift+F` | Search |
| `Cmd+P` / `ll` | Go to a list — every list and nested list, matched by the letters you type (`wsr` finds "Write the spring report"), with its folder beside it. Clicking the list's name at the top of the pane opens it too |
| `Cmd+Ctrl+I` / `Cmd+Ctrl+D` | The right dock on its Inspector / Done tab, or put it away |
| `Cmd+Shift+A` | The left dock's Agent tab — Claude Code, asking before every change |
| `Cmd+J` | The bottom dock: a graph of tasks done and added per day (Zed's bottom dock) |
| `Cmd+Alt+B` / `Cmd+Alt+Y` | The right dock / close all docks (Zed's) |
| `Cmd+I` | List settings |
| `Cmd+Z` / `Cmd+Shift+Z` | Undo / redo |
| `Cmd+Shift+P` / `Cmd+K` | The command palette — everything the workspace can do, and its key |
| `Cmd+/` | The same commands, grouped as a reference |
| `Esc` | Cancel what you are typing, or leave the surface you are in |

In the sidebar the keys are Zed's project panel's, lists standing in for files
and folders for directories: `Cmd+N` new list and `Cmd+Alt+N` new folder beside
the row you are on, `F2` rename, `Delete` delete (it asks), `Cmd+←` / `Cmd+→`
collapse / expand every folder, `Space` opens the row. Its vim panel's netrw
keys work too: `d` new folder, `%` new list, `Shift+D` delete, `Shift+R`
rename, `h` / `l` / `-` collapse, expand and go up, `gg` / `Shift+G` the ends,
`{` / `}` the previous / next folder and `:` the palette.

The palette, search, the list finder, the move picker, quick edits (`t`, `dd`,
`ee`…), the reference and the new list / folder / column prompts all open in
one **overlay** at the top of the window rather than as sheets. One is up at a
time and asking for another replaces it (`Cmd+K` from search opens the
palette); `Esc` or a click outside closes it, and `Return` confirms — in a
notes edit too, where `Shift+Return` is the new line.

The arrows read by modifier. Bare, they move the cursor; with `Cmd`, they move
it to the ends. `Alt` moves the *task* within its list — up and down among its
siblings, out and in a level. `Shift+Alt` carries it somewhere else — another
board column, another list. `Ctrl` is left to macOS, which gives it and the
arrows to Spaces and Mission Control.

The table above is the short version. The complete one is in the app: `Cmd+K`,
or a **double-tap of Shift**, opens the palette, and `Cmd+/` — or the keyboard icon in
the status bar — shows the same commands as a grouped reference. Both are rendered from a single catalogue in
`Sources/PriorityCore/WorkspaceCommandCatalog.swift`, which is also what the
key router dispatches through — so a key, a palette row and a reference row
cannot disagree about what happens. [`docs/keyboard-shortcuts.md`](docs/keyboard-shortcuts.md)
covers the behaviour a table cannot: sequence timing, which keys survive a text
field, which surfaces take the keyboard outright, and how to rebind any of it
in `~/Library/Application Support/Priority/keymap.json` (**Open the keymap
file** in the palette).

### Typing a task

A new task can say more about itself than its title. End it with any of these
and they are set as it is filed, rather than by opening the task again straight
afterwards:

| Ending | Sets |
| --- | --- |
| `30m`, `1h`, `1.5h`, `1h30m` | The estimate (up to a day) |
| `@today`, `@tomorrow`, `@fri`, `@3d`, `@2w`, `@2026-10-02` | The day it is due — a weekday means the next one, today included |
| `#work` | A tag — it has to start with a letter, so `#12` stays in the title |
| `!1`–`!4` | The priority |

`Write the release notes 45m #work @fri !1` files a task called "Write the
release notes", estimated at 45 minutes, tagged `work`, due on Friday, at
priority 1.

Only the **trailing** words are read, and the first word from the end that is
not one of these stops the reading — so a title is never rewritten in the
middle: `Read 30 pages` and `Buy 2m of cable` keep every word. The first word is
always the title's, and a second estimate, day or priority stops the reading
too, leaving the earlier one in the title where you can see it. As you type,
what will be set shows as chips beside the field — in the title bar's **Add a
task** and in the focus panel's "Add … to today" row — so nothing is a surprise
after Return.

### Coming from Checkvist

The desktop workspace supports Checkvist-style two-letter commands, including
`uu`, `ee`, `dd`, `nn`, `tt`, `mm`, `ll` and `hc`, plus native undo/redo in the
Edit menu. Board arrows navigate every column, including empty ones, and
`Up`/`Down` step through the subtask rows drawn on each card as well as the
cards (folded cards are skipped over); `Space` and `Return` act on the row you
are on. The sidebar outlines the list you are navigating.

Subtasks fold where they stand, as they do in Checkvist, so you can look
inside a task without opening it: in the outline `→` unfolds a task and steps
into its subtasks and `←` folds it and steps back out, `za` folds the task you
are on in the outline or on a board card, and every row with subtasks has a
chevron. Folds are shared by the outline and the board and kept across
launches — see [`docs/keyboard-shortcuts.md`](docs/keyboard-shortcuts.md#folding-subtasks-where-they-are).

A letter that begins a sequence and also means something on its own — `x`
(complete, or `xx`), `l` (open subtasks, or `ll`), `h` (leave them, or `hc`) —
waits up to 1.2 seconds for a second letter, then does its own job. Any other
key ends the wait at once, and holding Shift (`⇧X`) skips it. A letter that
begins no sequence where you are never waits.

The one-letter root tabs that used to collide with those sequences are gone
with the menu bar panel they belonged to, so a sequence no longer has to
compete with a tab for its starter letter.

## Today

The window opens on **Today**: the day as a numbered list of cards, the same one
the hotkey summons over other apps. One component, two mounts — a day that read
differently depending on where you opened it would be two days.

Each card carries what the task is, what it should cost, and what it has cost so
far. `Return` on a card starts it; the card you are on grows a live clock and a
strip of pause, skip, log and done, so a whole block runs without the list ever
going away.

The day also says when it ends: the header reads like `1h 20m of 3h · 1h 40m
left · done by 17:35` — what the estimated tasks still owe, worked straight
through from now, counting the block that is running. Tasks with no estimate
are left out of it (the tooltip says how many), and in the window clicking a
card's estimate, or its "No estimate", opens the same estimate editor as
`Option+T`.

The two mounts differ in their chrome only. In the window the pane is its header
— the scope, and time logged against the day's estimates — and the list, walked
with the ordinary selection keys like any other pane. The day's other numbers
are in the status bar (click them for the timeline), a task is added from the
title bar's field — which, while Today is up, puts it on today — and a search is
`Cmd+F`. The summoned panel has no title bar or status bar to lean on, so it
keeps its own: a bar of estimated against logged under the same finish time, a line setting today against
the week, a list of the day's logged blocks, and a field that searches every
task's title and notes and offers to add what you typed to today.

Anything already done is ticked off from here rather than somewhere else: each
card's number becomes a tick when the pointer is over it, and `Shift+Return`
does the same to the card you are on. Finishing plays whichever celebration is
configured, wherever it was finished from.

A task that owes the day a **daily contribution** is badged where it is read
rather than gathered into a screen of its own — a daily is a requirement placed
on an ordinary task, not a kind of item. Clicking the badge records today's
contribution without starting a block; the task itself stays open until it is
genuinely finished, and ticking off such a task records the contribution rather
than closing it.

The window also carries a strip naming which of the four modes is up, and the
two surfaces — Focus and Timeline — that take the pane away from them, so none
of it is reachable only by a key you have to already know.

| Key | Action |
| --- | --- |
| `Cmd+1` | Today |
| `Cmd+2` | Board |
| `Cmd+3` | Outline |
| `Cmd+4` | Matrix |
| `Cmd+8` | Focus — the pane that picks what to do next, or the block that is running |
| `Cmd+9` | The day's timeline |
| `Cmd+0` | Everything, across all active lists |
| `Ctrl+1` / `Ctrl+2` / `Ctrl+3` | Focus the sidebar, the task surface, the inspector |
| `Cmd+B` | Show or hide the sidebar (Zed's left dock) |
| `Up` / `Down` | Move between cards |
| `Return` | Start the card you are on, or finish the one running |
| `Shift+Return` / `Space` / `x` | Tick the card off without running a block |
| `Ctrl+T` | Plan the card for today, or take it off — an overdue or dated card becomes one you placed |
| `Alt+↑` / `Alt+↓` | Arrange the day: move a planned card earlier or later, whichever lists they came from |
| `Left` | Back to the list in the sidebar (the window) |
| `Cmd+Return` | Open the card in the main window (the panel) |

The digit row used to move the caret between the window's three panes. Changing
what you are looking at is the bigger thing, so it took the row and pane focus
moved to `Ctrl`.

## Focus

Focus is the pane that answers what to do next when the day list is not enough
— the ranked ladder, with the conditions and the time window that produced it.
`Cmd+8` from anywhere in the window takes the main pane; `Esc` gives it back.
The app opens on Today rather than here; the preference **Open on the focus
screen** puts it back to opening here.

The pane has two states and no third surface. With nothing running it is the
**ladder**: one task at a time at full size, the ones you have climbed past
stacked and shrunken above it, with the reason each was offered written under
its title. Once a block starts, the same pane *is* the block — the task, a
clock, and the four things you can do to it.

| Key | Action |
| --- | --- |
| `↑` / `↓` | Climb the ladder. `k` / `j` do the same |
| `⌥↑` / `⌥↓` | Reorder within the same urgency, rather than moving the cursor |
| `O` | Drop your own order and go back to the computed one |
| `Return` | Stage the task, then start it. `Space` does the same |
| `X` | Tick it off without starting a block |
| `L` | Put it off — the menu beside it chooses when |
| `Esc` | Unstage, then leave |

While a block is running:

| Key | Action |
| --- | --- |
| `Return` | Done — stops the clock and asks how it went |
| `P` | Pause / resume. Only active time is recorded |
| `L` | Log progress and keep the task open |
| `F` | Float it — a small always-on-top clock for working in another app |
| `Esc` | Leave the pane. The block keeps running |

The quality question is what turns minutes into points, so it is asked by
default — but **Ask how each focus block went** in Settings turns it off, and
blocks then close at ×1 without stopping.

The floating clock is a **companion, not a remote control that needs its
station**: it names the task, draws the block's progress as a hairline, and
carries pause, log and done, so closing the main window while a block is running
leaves the clock up rather than taking it away. It appears on its own whenever
the last window closes on a running block.

`Cmd+9` gives the same pane to the day's **timeline**: every block drawn against
an hour ruler, with the running one growing live.

### The focus panel

`⌃⌥⇧⌘F` summons the focus panel over whatever app you are in — the one surface
you can reach without going to the app. It comes up with the caret already in
its field, so there is nothing to click, and it comes up **alone**: the main
window stays wherever you left it, open or closed, rather than being dragged
forward along with it.

It **stays where you put it**. Clicking back into your editor does not dismiss
it: it floats above the other window, at the size and position you gave it,
until you press `Esc` or the hotkey again. Drag it anywhere, drag its edges to
resize, and it comes back the same next time. It is a panel you leave up while
you work, not an overlay you summon and lose.

What it shows is **the day as a list of cards**, numbered, each with its
estimate and the time already on it, under a bar showing what the day is meant
to cost against what it has cost so far.

The day is not only what you dragged into the Today column. It is, in order:
the block you are running, then whatever you put on Today by hand, then
anything overdue, then anything **due today**, then anything **starting
today**. Each task appears once, under the strongest reason that claims it, and
the card says which — so work with a date on it turns up in the panel without
you having to go and find it first. A task you placed on Today by hand still
outranks every automatic reason, because a plan you made is a decision and a
due date is only a fact. The planned cards are also the only ones you arrange:
`Ctrl+T` plans the card you are on (or takes it off), and `Alt+↑` / `Alt+↓`
move a planned card through the day. A dated card stays where its date puts it
— press `Alt+↓` on one and the status bar says to plan it first. Press a
card and it starts; the card you are on grows a live clock and its own strip of
controls — pause, skip, log, done — while the rest of the list stays visible
underneath. Finished work collects at the bottom, one line per task rather than
one per sitting.

It deliberately does **not** put you through the focus screen's questions.
Conditions, an available-time window and an estimate to commit to before you may
begin are how you decide what a day should be; this is the panel you keep open
while working it, so pressing play on a row is the whole gesture.

Everything a block needs it can do on its own — pick the task, run the clock,
pause it, log progress, and score the block when it ends. Nothing in it reaches
for the main window, so **Priority needs no Dock icon** for any of it: close
the main window and the app drops to the menu bar, and the panel keeps working
exactly as before, keyboard included. Closing the window while the panel is up
hands the caret straight back to it.

Under the day's bar, a second line sets today against **the week it belongs
to**: how many tasks you have finished today, how much time the week has taken
so far, and what that comes to per day over the days that have actually
happened. There is no target to configure first — the week is its own
denominator, which is the only way to know whether a thin-feeling day really is
one.

| | |
| --- | --- |
| **Empty field** | The day's cards, running task first. A day that claims nothing falls back to the ranked shortlist |
| **Anything typed** | Every task whose title or notes match, wherever it lives, with *Add “…” to today* at the foot |

| Key | Action |
| --- | --- |
| `↑` / `↓` | Choose |
| `Return` | Start it — or, with a block already running, queue it. On the running card, Done. On the add row, create it in Today |
| `Cmd+Return` | Open it in the main window instead |
| `Esc` | Clear the field, then hide the panel |
| `Cmd+C` / `Cmd+V` | Copy and paste, sent straight to the field — an app with no Dock icon has no Edit menu to route them |

Hiding it hands the keyboard back to the app it interrupted, so summoning it
mid-sentence and pressing `Esc` puts the caret back where it was. Clicking away
instead leaves the panel up and makes no such promise. The status
item's context menu has **Focus Panel** too, so the hotkey is a shortcut for
something visible rather than the only way in. Rebind or disable it in
Preferences → Keybindings.

## Command palette

`Cmd+K`, or a **double-tap of Shift**, as in Checkvist. A modifier on its own
produces no key-down event, so `⇧⇧` is recognised as a gesture rather than
bound as a shortcut; Shift held for a capital letter counts as a chord rather
than a tap, so typing never trips it. It opens from inside a text field too,
since leaving the field to do something else is most of what it is for.

Type to narrow. A prefix of the name beats a match in the middle of it, the
initials work (`atk` finds *Add a task*), and so does typing the key itself —
`cmd+shift+d` finds the command that key runs, which is the answer to "what
was that shortcut again" as often as the name is. Commands for the surface you
are on sort first; the rest stay listed rather than disappearing, because the
palette is also how you find out that a surface you are not on has the thing
you want.

Every row carries its key, and rows that have no key say so plainly rather
than looking unbound. Rows for the arrows, `J`/`K`, `Home`/`End` and the
priority digits are listed too, dimmed and not selectable: they move a cursor,
and the palette has already taken the keyboard away from wherever that cursor
was, so running one from a list would do nothing you could see. They are shown
because "what can I press here" is a fair question about them.

### Typed commands

Separately from the palette above, `CommandEngine` parses a text command
language inherited from the Checkvist-era menu bar panel. **It currently has no
surface** — `AppCoordinator.executeCommandInput` has no callers — so the
families below parse and are tested but cannot be reached from the app. They
are documented because the parser is still there and still correct, not because
you can type them today. Most accept several spellings: `unrepeat`, `no
repeat`, `remove repeat` and `clear repeat` all do the same thing.

| Family | Commands |
| --- | --- |
| **Status** | `done`, `undone`, `invalidate`, `delete`, `undo` |
| **Due** | `due <value>`, `clear due` |
| **Start date** | `start <value>`, `edit start`, `clear start` |
| **Repeat** | `repeat <rule>`, `repeat daily`, `repeat every <n> <unit>`, `clear repeat` |
| **Tags** | `tag <name>`, `untag <name>` |
| **Priority** | `priority <1-9>`, `priority back`, `clear priority` |
| **Matrix** | `matrix do` / `schedule` / `delegate` / `eliminate`, `matrix <u> <i>`, `importance <value>`, `urgency <value>`, `clear matrix` |
| **Kanban** | `kanban left` / `right`, `kanban move left` / `right`, `kanban enter`, `kanban exit`, `kanban show in all`, `kanban focus mode`, `kanban swimlanes` |
| **Outline** | `expand`, `collapse`, `expand all`, `collapse all`, `enter children`, `exit parent` |
| **View** | `list <name>`, `tab <name>`, `cycle tab next` / `prev`, `cycle filter next` / `prev`, `toggle children`, `toggle subtree`, `toggle context`, `toggle hide future` |
| **Timer** | `focus mode`, `toggle timer`, `pause timer` |
| **Obsidian** | `sync obsidian`, `open obsidian new window`, `link` / `create` / `clear obsidian folder`, `choose obsidian inbox` |
| **AFFiNE** | `sync affine`, `open affine`, `affine daily` |
| **Calendar** | `sync google calendar`, `open google calendar` |
| **MCP** | `mcp guide`, `mcp config`, `copy mcp config`, `refresh mcp path` |
| **App** | `preferences`, `search`, `quick add`, `refresh lists`, `upload offline tasks`, `window`, `diagnostics` |

Due values understand natural language and times: `due today 14:30`, `due tomorrow 9am`, `due next week`, `due 4pm fri`, `due next monday morning`. The time words `morning`, `noon`, `afternoon`, `evening`, `midnight`, `eod` and `cob` all resolve to configurable named times.

The **Kanban**, **Matrix** and **View** families act on the Checkvist-side state
the removed menu bar panel rendered. What they change no longer has a surface
either, so they are doubly stranded — a workspace that has not finished
migrating, reachable by nothing.

## Views

Four planning modes, one focus screen, one timeline. The mode strip in the title
bar names the one you are in — in ink, on a quiet fill, the others muted — and
its tooltips give every key that reaches the others; Focus and Timeline sit at
its end, set apart by a rule.

| Mode | Key | What it shows |
| --- | --- | --- |
| **Today** | `Cmd+1` | The day as a numbered list of cards — see [Today](#today) |
| **Board** | `Cmd+2` | Columns of cards, dragged between and within |
| **Outline** | `Cmd+3` | The list as a tree, indented, with each branch folding in place |
| **Matrix** | `Cmd+4` | Eisenhower quadrants by importance and urgency |
| **Focus** | `Cmd+8` | What to do next, or the block that is running |
| **Timeline** | `Cmd+9` | The day as elapsed time rather than as a list |

`Cmd+0` shows **Everything** — every active list at once, rather than the one
the sidebar has selected.

There used to be seven views instead, keyed `q` through `u`, inside a menu bar
panel: All, Due, Tags, Priority, Kanban, Matrix and Daily. Due, Tags and
Priority were filters over one list wearing the costume of separate places, and
Daily was a dashboard for a thing that is now a badge on a task. What is left
is the four that ask genuinely different questions.
## Repeating work

Give a task a **period** — `daily`, `weekdays`, `weekly`, `every 3 days`,
`every 2 weeks`, `every monday` — and finishing it schedules the next one.

The occurrence you did stays done. It keeps the day it was finished on and
counts towards the week like any other completed task, and a *new* task is
written for the next time round, dated by stepping the cadence from the dates
this one carried. A single row flipped back to open could only ever record the
last time you did it, which is a week of work that reads as a week of nothing.

Missing a few is not a reset: the cadence steps until it lands in the future,
so `every 3 days` ignored for a fortnight comes back on its own grid rather
than arriving already overdue. Nothing pushes the repeat into today — it
carries a start date, and **the day already claims whatever starts today**.
That pair is the whole of the autoscheduling; there is no third mechanism and
nothing to turn on.

The repeat arrives without a column or a ladder position, because a plan for a
day nobody has made yet is not a plan.

## The menu bar

The status item is a **standing reminder**, not a launcher. It names the next
thing on today — or, while a block is running, that task and its clock — and
clicking it drops the day down as a menu you can start any task from without
the app ever coming to the front. Overdue work is coloured; the tick marks
whatever is running.

It also **outlives the window**. `⌘Q` closes the windows and leaves the status
item behind, because a reminder you can dismiss with a keystroke is not a
reminder. The only quit that actually quits is **Quit Priority** in the status
item's own menu.

## The window

The window is the app. It opens on Today, carries the mode strip and the add
field in its title bar, and everything you can do you can do here. It is laid
out the way an editor is — Zed's layout, specifically: flat surfaces split by
hairlines, every column topped by a header band of one height so a single rule
runs straight across the window under all three, and exactly one strip along
the bottom.

- **Title bar** — the window's title after the traffic lights, the mode strip
  (words only), and **Add a task** on the right (`a` or `Cmd+N` to reach it).
  It names where the task will land: the list on screen (inside the task you
  have opened, if any), the folder's chosen list (`Cmd+Alt+[` / `]` to change
  it), or the **inbox** when no one list is on screen — Everything included.
  On Today it also puts the task on today, and says so (`Today · Inbox`).
  Pressed on a task, `a` / `Alt+Return` / `Alt+Shift+Return` place it below,
  above or inside that task instead.
  Endings like `30m`, `@fri`, `#work` and `!1` set the task's estimate, due
  day, tags and priority, and show as chips before you press Return — see
  [Typing a task](#typing-a-task).

- **Left dock** — two tabs, **Lists** and **Agent**, in a tab bar like the
  right dock's; its tab, visibility and width are remembered.
  - **Lists** is the sidebar of lists and folders. Lists only: Focus and the
    timeline are in the mode strip, not repeated as sidebar rows. The tab bar
    carries its actions as small glyphs — new list (`Cmd+Shift+N`), new folder
    (`Cmd+Alt+N`), archived lists to restore (only while there are any), and
    undo/redo — rather than a bar along its foot; hover one for its name and
    key.
  - **Agent** (`Cmd+Shift+A`) is an assistant panel in the manner of Zed's: your
    own Claude Code, run headless, with Priority's MCP server as its only
    tools — no shell, no files, no web, and no API key (it uses your Claude
    Code login). It **reads freely** — the lists, tasks, dailies, the day log
    and the focus timer — and each read shows as one muted line in the
    transcript. **Every change** — adding, editing, completing, moving or
    deleting anything — stops as a card saying what it will do (the tool, the
    title, the list by name) with **Approve** and **Deny**; nothing runs until
    you click Approve, or press Return with the card holding the keyboard
    (Tab from the field reaches it; Esc denies). Stopping the thread, starting
    a new one, or the process dying withdraws an unanswered card, and the
    change never happens. Return sends, Shift+Return is a new line, Esc hands
    the keyboard back to the tasks; the glyphs on the tab bar start a new
    thread and stop the current one. Approved changes are ordinary "MCP: …"
    steps in the Undo menu. If Claude Code is not installed where Priority
    looks (`~/.local/bin`, `~/.claude/local`, Homebrew, `/usr/local/bin`), the
    panel says so and takes a path. See
    [`docs/agent-panel.md`](docs/agent-panel.md).
- **Main pane** — a header band with where you are on the left (the scope, and
  the way back out of an opened task) and a count or a few glyph buttons on the
  right, then the mode's content. Panes carry no footers of their own: their
  key hints are in the reference (`Cmd+/`) and the palette (`Cmd+K`).
- **Right dock** — the inspector and the done rail, as two tabs of one
  resizable column, in a tab bar: the showing tab in ink with a rule under it,
  the done rail's tally and a close glyph at its right. Its visibility, width
  and tab are remembered, and it does not close itself when you navigate; with
  nothing selected the inspector says so.
- **Bottom dock** (`Cmd+J`) — under the main pane, the progress graph: a bar
  per day for the tasks closed and a line for the tasks added, over 7, 30 or
  90 days, with the totals and the net in its header (hover a day for its own
  figures). Its visibility, height and period are remembered.
- **Status bar** — a thin strip along the foot, glyphs at its ends like an
  editor's. On the left, the left dock's Lists and Agent toggles and the
  bottom dock's Progress toggle (the Lists
  tooltip says which region has the keyboard); in the middle, a half-typed key sequence (`d…`), an error,
  or a passing message; on the right, the running block and its clock (click to
  return to it), today's time logged, points and tasks done (the week's in the
  tooltip; click for the timeline), Google Tasks sync, and at the right edge
  the right dock's Inspector and Done toggles — each toggle on the side its
  pane opens on.

A selected row is a quiet fill; the row the keyboard is on adds a one-point
line in the focus colour, so which pane will answer the arrow keys is always
visible without a thick ring. Empty panes say so in one line of muted text in
the middle.

Preferences is `Cmd+,` and the app menu; there is no gear in the window.

It used to be the second-class half of a pair. The first-class half was a
400pt menu bar panel that dismissed on any outside click — right for a glance,
wrong for half an hour of reorganising — and the window existed so the same
views had somewhere to live that survived being clicked away. That panel is
gone; what is left of the menu bar is a standing reminder and a way in.

Open it from **the status item's menu → Open Main Window**, from **Window →
Priority** in the menu bar, or with the global hotkey. It is resizable, remembers its
frame, and `Esc` leaves it alone.

**A Dock icon appears while the window is open** and goes again when you close
it. That is what buys you `Cmd-Tab`, `Cmd-W`, `Cmd-Q` and — the one you notice
if it is missing — an Edit menu, without which copy and paste do nothing in
the quick-add field.

The **global focus panel** is the one surface that is not the window: it is
the same day list, summoned over whatever app you are in, and it keeps working
with every window closed.

## Themes

Pick a look in **Settings → Theme**: **Chalk**, the house style, which follows
your Light/Dark setting, or **Chalk Dark**. Your own themes are JSON files in
`~/Library/Application Support/Priority/themes/`, and they appear in the same
picker. A file can extend a built-in and change only a few colours or sizes,
and the app reloads it as you save, so the easiest start is **Export the
current theme as JSON** in the command palette — it writes a complete copy,
opens it and switches to it. **Open the themes folder** and **Reload themes**
are there too. A broken file is reported on the status line and in
Diagnostics, never fatal.

**Format and a full example: [docs/themes.md](docs/themes.md)**

## Diagnostics

**Show diagnostics** in the command palette, or **Workspace → Diagnostics**. It opens as
a sheet on the main window and answers "why does this look wrong?":

- **Status** — connection, current list, network, sync age, open task count, and whether anything is queued offline.
- **Health** — a green tick or an orange triangle per integration, with the detail underneath. The AFFiNE row lists every path it searched for the helper; the MCP row shows the resolved command; the Google Calendar and Google Tasks rows show whether the shared Google sign-in covers them.
- **Recent problems** — every failure this session, timestamped. Worth having because nothing else keeps one: the error line is overwritten by the next thing that fails, the status message erases itself after three seconds, and integration errors were not retained at all. Not written to disk — it covers this run of the app, not last fortnight's.
- **Data** — where everything lives, with a Reveal button each, including `~/.config/priority/config.json`, which belongs to the CLI rather than the app and is a recurring source of confusion.

**Copy Report** and **Export Report…** produce plain text you can paste into an
issue. Both run it through a redactor first: anything labelled like a
credential, and any bare token-shaped run, comes out as `<redacted>`. Check it
before you post it anyway.

## Daily log

What the app writes down about a day, and what reads it back.

### Dailies
A daily is not a kind of item and not a view. It is a requirement placed on
an ordinary task: contribute to this every day. The task keeps its place in
its list and gains a badge on its card in Today that you tick to record the
day's contribution, without starting a block.
Recurring things you intend to do — habits, not tasks — sitting at the top of the view as a checklist.

- **They reset at every rollover and never go overdue.** Miss one and it's a gap in the history: nothing to clear, nothing to reschedule. That's the whole reason they aren't Checkvist tasks with a `repeat daily` rule — a recurring *task* goes overdue and starts competing with real deadlines.
- **They're local.** Stored in `~/Library/Application Support/Priority/dailies.json`, so "brush teeth" never clutters your project lists or syncs to other Checkvist clients. Ticking one is instant and works offline.
- **Ticks land in the same log as task completions**, so they appear in the Obsidian note alongside them. The chart plots the ticks alone: a day's task count is whatever happened to be on the list, and summing the two in let it swamp the routine the chart sits under.
- **Two kinds of schedule.** Fixed weekdays (`Mon Wed Fri`, weekdays, weekends, every day) or a rotating cycle — every other day, every three days — counted from the day you set it. A cycle walks through the week, so it's the one for "water the plants", not "standup".
- **Set the schedule as you type** from the menu in the add field, or edit any daily in full — day-by-day toggles, cycle length — in `Preferences → Plugins → Daily Log`.
- **Rename in place with `a`, delete with `Delete`**, without leaving the checklist. Deleting *archives*: the row goes from today's list and from the editor, but every past day that ticked it still renders with its title rather than a raw id, and it can be restored from the Deleted list in `Preferences → Plugins → Daily Log`. That is why deleting needs no confirmation — nothing has been lost.

### What the day records

- **Recording is always on and always local.** Completions, reopens, invalidations, finished focus sessions and the day's plan are appended to `~/Library/Application Support/Priority/daylog.jsonl` — one JSON object per line, so it stays readable with `tail`, and a torn write costs one event rather than the file.
- **Checkvist owns current state, the log owns history, Obsidian owns the archive.** Nothing syncs backwards, so there is no conflict resolution anywhere in this.
- **The day's plan is derived, not authored.** The first time you open the app after your rollover hour, whatever is due, overdue or starting that day is snapshotted. That's what the day's note measures its "N of M planned left" against — you never plan a day by hand.
- **Deferring is not slipping.** Pushing a due date forward is recorded distinctly from letting a task rot, so the view doesn't nag about a decision you made deliberately.
- **The day starts at your rollover hour, not midnight** (default 04:00), so a session finishing at 01:30 counts towards the day it belonged to.
- **No backfill.** History starts the day you first run this build. The chart is drawn from day one regardless — a flat run of days is a true statement about a history that has just started — with a "collecting since" line underneath until the window fills.

## Obsidian daily notes

In `Preferences → Plugins → Daily Log`, point Priority at your dailies folder and set the note naming to match your vault (`yyyy-MM-dd` by default; a subfolder pattern like `yyyy/MM` nests them). The preview line shows exactly which note today's block would land in. Then switch on "Write days into Obsidian daily notes", which stays disabled until a folder is chosen.

Once a day closes, its block is spliced into that day's note:

```markdown
<!-- priority:begin -->
## Log

**5 done** · **2/3 dailies** · **1h 40m focused** · 2 of 7 planned left

_Dailies:_
- [x] Read
- [x] Walk
- [ ] Stretch

- [x] Ship the DMG
- [x] Review the sync PR

_Unfinished:_
- [ ] Write release notes
<!-- priority:end -->
```

Only the text between the markers is ever touched, and rewriting a day replaces its own block rather than stacking a second one. **Creating missing notes is off by default**, so the plugin can't beat a Templater or Daily Notes template to the file — turn it on only if nothing else builds your dailies.

## AFFiNE

Priority keeps a two-way checklist in an [AFFiNE](https://affine.pro) workspace. `sync affine` writes your list's open tasks as real todo blocks under a `## Tasks` heading in that list's document — and reads back what you ticked in AFFiNE, closing those tasks in Checkvist before it writes:

```markdown
## Tasks

- [ ] [Write the release notes](https://checkvist.com/checklists/12#t34)
  - [ ] [Draft the summary](https://checkvist.com/checklists/12#t35)
- [x] [Ship the DMG](https://checkvist.com/checklists/12#t31)   ← ticked here, closed there
```

`affine daily` writes the day's log into that day's document, the same block the Obsidian writer produces.

AFFiNE documents are CRDT block trees rather than text, so the writing is done by [`affine-mcp-server`](https://github.com/DAWNCR0W/affine-mcp-server), which Priority launches and drives over MCP:

```bash
npm install -g affine-mcp-server
affine-mcp login
```

Then switch the plugin on in `Preferences → Plugins → AFFiNE` and click **Load Workspaces**. Your AFFiNE credentials stay in that helper's own config — Priority never handles them. Priority owns the `## Tasks` heading and what sits under it; everything else in the document is yours, and an item you typed in by hand is put back rather than deleted.

**Details: [docs/affine.md](docs/affine.md)**

## Command line

`priority` is a Rust CLI covering the same ground: your lists, your dailies, your day log. It talks to the Checkvist API directly and reads Priority's local files off disk, so it works whether or not the app is running — and its writes take the same `flock(2)` the app does, so both can be open at once.

Run it with no arguments and it opens a **terminal UI with the same tabs as the app**, and the same keys to reach them:

```
 All q │ Due w │ Tags e │ Priority r │ Kanban t │ Matrix y │ Daily d
┌ All ───────────────────────────────────────────────────────────────┐
│▎[ ] Ship v0.4                                                      │
│   [ ] Draft the release notes  #work                               │
│   [x] Tag the commit                                               │
│ [ ] Buy milk  #home                                                │
└────────────────────────────────────────────────────────────────────┘
 j/k move · l/h in-out · space done · a add · ? help · esc quit
```

Or drive it by subcommand:

```bash
./scripts/install_cli.sh     # release build + a symlink onto your PATH
priority auth login

priority                     # the terminal UI
priority tasks
priority add Draft the release notes --due friday
priority search -q report --due-before 2026-09-01
priority daily add Read for twenty minutes --weekdays mon,wed,fri
priority daily add Water the plants --every-days 3
priority log --days 7
priority --json dailies | jq '.dailies[] | select(.done | not)'
```

Its credentials are its own, in `~/.config/priority/config.json` at mode 0600 — separate from the app's login-keychain item, so neither depends on how the other was built or signed. The dailies, log and metadata commands need no credentials at all.

Every command is one of the MCP tools under a friendlier name, and the same binary serves them over MCP with `priority mcp`. It is also the app's MCP server: Priority.app ships this binary at `Contents/Helpers/priority`.

**Full guide: [docs/cli.md](docs/cli.md)**

## MCP server

Priority exposes **21 MCP tools** so an AI assistant can work with your lists directly — fourteen that reach the Checkvist API, and seven for the local state Checkvist has no representation for (day log, dailies, priority ranks, recurrence, and the matrix).

All but one are reads or Checkvist writes. `task_matrix_set` places tasks on the Eisenhower matrix in bulk (`priority matrix <id>:<urgency>:<importance> …` from a terminal), and refuses while Priority is running — the app holds those coordinates in memory and would overwrite them. Quit Priority, let the assistant do a first pass over the whole list, then reopen and correct it by dragging.

Set it up from `Preferences → Plugins → Native MCP Integration`. It detects Claude Code, Claude Desktop, Cursor, Windsurf, VS Code and Zed, and adds Priority to the one you pick in a single click, preserving any servers already in that client's config.

There is one implementation — the Rust CLI — and the app ships it at `Contents/Helpers/priority`, so it works whether or not you installed the CLI separately. `Priority --mcp-server` hands the process over to it, which keeps configurations written for older versions working unchanged. There were three implementations once; `scripts/mcp_smoke_check.py` is what remains of holding them together, and it now only checks that handover.

**Full guide: [docs/mcp-server.md](docs/mcp-server.md)**

## Plugins

Every external integration is a plugin behind a protocol.

Built in: `NativeCheckvistSyncPlugin`, `NativeObsidianIntegrationPlugin`, `NativeAFFiNEIntegrationPlugin`, `NativeGoogleCalendarIntegrationPlugin`, `NativeMCPIntegrationPlugin`, `NativeDailyLogPlugin`, `OfflineTaskSyncPlugin`.

To install your own, open `Preferences → Plugins` and click **Install Plugin** (folder, `.zip`, or `.priority-plugin`), or drop a plugin folder into `~/Library/Application Support/Priority/Plugins` and hit **Reload**.

Built-in plugins are fully functional; user-installed plugins are manifest-driven (settings, metadata, lifecycle) and prepared for runtime capability wiring.

**Authoring guide: [docs/plugins.md](docs/plugins.md)**

## Build from source

Requirements: macOS 15.6+, Xcode 17+, and [Rust](https://rustup.rs) for the CLI.

```bash
git clone https://github.com/MaybeItsSoftware/priority.git
cd priority

# The app
xcodebuild -project 'Priority.xcodeproj' -scheme 'Priority' -configuration Debug -destination 'platform=macOS' build

# Headless logic (658 tests)
swift test

# The CLI (92 tests) — also the app's MCP server, bundled during the app build
cargo test --manifest-path cli/Cargo.toml

# `Priority --mcp-server` still reaches it
python3 scripts/mcp_smoke_check.py

# Build + launch Debug, or produce a release DMG
./scripts/run.sh
./scripts/build_dmg.sh <version>
```

### Layout

| Path | What |
| --- | --- |
| `Priority/` | The macOS app. |
| `Sources/PriorityCore/` | Pure, headless, UI-free logic. The app links it as a package product. |
| `Priority/Plugins/` | Integration plugins, one folder each, behind protocols |
| `cli/` | The Rust CLI crate — shares no source with the Swift side |
| `scripts/` | Build, install, the Python MCP fallback, and the parity check |
| `docs/` | [CLI](docs/cli.md) · [MCP](docs/mcp-server.md) · [plugins](docs/plugins.md) · [state ownership](docs/state-ownership.md) |

The same source tree is compiled by two build systems: the Xcode project builds the app, and `Package.swift` exposes `PriorityCore`, `PriorityPlugins` and `PriorityAppLogic` as SPM libraries so the headless logic can be tested without the app shell. Adding or moving a file often means updating `Package.swift` too — see [CLAUDE.md](CLAUDE.md).

## Where your data lives

| Path | What |
| --- | --- |
| `~/Library/Application Support/Priority/` | Dailies, day log, task cache, installed plugins |
| `~/Library/Preferences/uk.co.maybeitsadam.priority.plist` | Settings, priority ranks, recurrence rules, start dates |
| Login keychain, service `uk.co.maybeitsadam.priority` | The app's Checkvist remote key |
| `~/.config/priority/config.json` | The CLI's own credentials, mode 0600 |

Nothing is sent anywhere except Checkvist, and Google Calendar, Google Tasks or Obsidian if you enable them.

Google Tasks, when enabled, is a **mirror**: each list becomes a Google Tasks list of the same name, and Priority is the source of authority. Ticking a task off on your phone completes it here, notes you add there are kept, and a task you type there is adopted — but an edit that overwrites what Priority holds is replaced and written to a conflict log. `docs/google-tasks.md` has the full table.

> Upgrading from **Bar Tasker**? Everything is carried across automatically on first launch — preferences, dailies, the day log and your keychain item. The old locations are copied rather than moved, so they stay on disk until you delete them.

## License

MIT
