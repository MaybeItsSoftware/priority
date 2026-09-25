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
- [Views](#views) · [The window](#the-window) · [Diagnostics](#diagnostics) · [The dock row](#the-dock-row)
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
| 3 | Global hotkey to toggle the popover |
| 4 | Focus panel hotkey — `⌃⌥⇧⌘F` by default |
| 5 | Quick-add hotkey, and whether it targets the list root or a specific parent |
| 6 | Day rollover hour — when your day starts, default 04:00 |
| 7 | Obsidian inbox folder *(optional)* |
| 8 | MCP integration *(optional)* |
| 9 | Launch at login |

Onboarding boxes guide the Checkvist, Obsidian and Google Calendar setup. Each one is dismissable, and the app stays usable offline-first without any of them.

## Keyboard flow

### Navigation

| Key | Action |
| --- | --- |
| `j` / `↓` | Next task |
| `k` / `↑` | Previous task |
| `l` / `→` | Expand the task — subtasks appear indented underneath — then step into them |
| `h` / `←` | Collapse, step back out to the parent row, or leave the scope |
| `Shift+→` / `Shift+←` | Zoom in: the list becomes that task's subtree, and back out. Also `]` / `[` |
| `Ctrl+←` / `Ctrl+→` | Cycle root view |
| `q` | All view |
| `w` | Due view |
| `e` | Tags view |
| `r` | Priority view |
| `t` | Kanban view |
| `y` | Matrix view |
| `u` | Daily view |
| `?` | Every shortcut, on your own bindings — led by what applies in the view you're in |
| `Esc` | Cancel input / close popover |

### Task actions

| Key | Action |
| --- | --- |
| `Space` | Complete |
| `Shift+Space` | Invalidate ("won't do") |
| `Enter` | Add sibling below |
| `Alt+Enter` | Add sibling **above** |
| `Shift+Enter` | Add child |
| `Tab` / `Shift+Tab` | Indent / unindent |
| `Cmd+D` | Duplicate — content only, no due date, tags or subtasks |
| `Shift+A` | Quick-add at the configured location |
| `dd` | Open the due-date calendar; arrows move the date, `Return` applies, `Esc` cancels |
| `dt` | Type a due date and time (for example `today 14:30`) |
| `Cmd+↑` / `Cmd+↓` | Move task |
| `1`–`9` | Scoped priority rank, within the parent |
| `Hyper+1`–`Hyper+9` | Absolute priority rank (`Ctrl+Cmd+Option+Shift`) |
| `=` | Send to priority back |
| `-` / `0` | Clear scoped priority |
| `Hyper+-` | Clear absolute priority |
| `'` | Start a focus session on the selected task, from any view |
| `Cmd+Z` | Undo the last change |

### Kanban

| Key | Action |
| --- | --- |
| `h` / `←` | Previous column |
| `l` / `→` | Next column |
| `Cmd+←` / `Cmd+→` | Move task between columns |
| `f` | Show this task in the All view, entering its subtasks if it has any |
| *drag* | Drop a card on another to place it above that card, or below the last card to send it to the end. Dropping inside the same column reorders it without touching its due date, priority or position |

### Matrix

Placement is two keystrokes. `m` on its own spells the rest out in the status
bar, so the vocabulary is one keypress away rather than something to memorise.
Every sequence starter does this — `d` lists the due and start sequences, `g`
the tag and link ones — built from the bindings in force, so a rebound sequence
still names its real key.

| Key | Action |
| --- | --- |
| `md` | Do — urgent and important |
| `ms` | Schedule — important, not urgent |
| `mg` | Delegate — urgent, not important (`g`, because `d` is Do) |
| `me` | Eliminate — neither |
| `m<u><i>` | An exact coordinate, each axis `-9` to `9`. `-` before a digit makes it negative: `m-3 5`, `m5-2`, `m-4-4` |
| `m00` | Take the task off the matrix |
| `mz` | Zoom into the selected dot's quadrant, so one box fills the grid. Again, `Esc` or `←` to zoom out. Clicking a quadrant's name does the same |
| `ml` | Show or hide the unplaced list (also the dock's tray button) |
| `↑` `↓` `←` `→` | Move the selection between dots — one coordinate at a time, nearest on the other axis breaking the tie. `j` `k` `h` `l` do the same. `↑` with nothing above it reaches the tab strip |
| `⏎` | Open the dot the selection is on — lists everything standing on that point in the drawer. `↑` `↓` walk it, `←` or `Esc` closes it. Double-clicking a dot does the same |
| *drag* | Drop a task anywhere on the grid to place it there. Drag from the unplaced list, or drag a placed dot to move it. Dropping a dot back into the list unplaces it |

With the Matrix view open, placing a task steps the selection to the next
unplaced one — the next entry in the drawer, wrapping once — so a backlog is
sorted by typing `md` `ms` `me` down it without moving the cursor by hand. It
walks the drawer's own list, so the count you can see is the number of presses
left; an inherited coordinate counts as placed for both.

A dot is usually a pile rather than a task. Inheritance gives a goal and its
whole subtree the *same* coordinate, so forty tasks draw as one dot and the plot
has no way to tell them apart — which is what opening a dot is for. The drawer
lists the pile, marks the one task that chose the coordinate as `GOAL`, and
selects whatever you move to, so the ordinary keys — done, due, tag, timer —
apply without leaving the matrix.

The arrows step by *level* rather than by distance, so repeated presses walk
every distinct row and column of the plot and no dot is stranded — a
nearest-neighbour rule leaves a dot alone in a corner that nothing can reach.
From a task with no coordinate the first press joins the plot at the dot
nearest the middle. The card along the bottom names whatever the keyboard is
on, or whatever the pointer is on when it is over a dot; hovering elsewhere
names nothing, because a dot only answers to a pointer inside its own
catchment.

The unplaced list is a drawer under the grid rather than a column beside it,
and it is **off by default** — as a permanent rail it took 190 of the panel's
400 points, which left the grid as the narrower half of its own view. Opening
it lengthens the panel by the drawer's own height, so the grid stays the square
it was. `m` on its own names the key in the status bar, along with the
placement letters.

A task with no coordinate of its own takes its nearest placed ancestor's, so
placing a handful of goals classifies everything beneath them. An inherited
coordinate is a starting point rather than the answer: the task's **own due
date and priority rank** move it inside its goal's point — sooner is further
right, higher-ranked is further up, and a task with neither sits below its
siblings. Those are whole steps, with a small stable nudge on top to separate
tasks the facts leave tied: the nudge is exactly half a step, so it fills its
own cell and can never draw a task as more urgent than one genuinely due
sooner. Without it the plot read as a lattice, because most tasks share a due
date of *none* and a rank of *none*. The drift can never cross an axis, so it
orders tasks within a quadrant and never argues with which quadrant the goal
was put in. Inherited dots are drawn hollow because the position is read off
the task rather than chosen for it.

`Do` fills up faster than the other three, and a quadrant is only a quarter of
the glass. Zooming rescales the window rather than the data: the same
coordinates through a smaller frame, with the other three boxes out of view, the
arrow keys confined to the one you are in, and a drop landing on a coordinate
that belongs to it.

Placing a task by hand overrides all of that — a coordinate you set is exactly
where the dot goes. Where several tasks still land on the same point, the plot
draws **one dot per point, not per task**: it grows with the pile, carries the
count beside it, and `⏎` opens it.

### Dailies

| Key | Action |
| --- | --- |
| `j` / `k` | Move through the checklist |
| `Space` | Tick / un-tick |
| `Return` | Add a daily — stays open, so a whole routine can be typed in one go |
| `a` / `i` | Rename the selected daily in place |
| `Delete` | Delete it. Past days keep their record, and it can be restored in Preferences |
| `Cmd+↑` / `Cmd+↓` | Reorder |
| `Esc` | Cancel adding or renaming, discarding what's been typed |

### Coming from Checkvist

The desktop workspace supports Checkvist-style two-letter commands, including
`uu`, `ee`, `dd`, `nn`, `tt`, `mm`, `ll`, and `hc`, plus native undo/redo in the
Edit menu. See the [desktop keyboard reference](docs/keyboard-shortcuts.md) or
press `?` / double-tap Shift. Board arrows navigate every column, including
empty ones; the sidebar outlines the list you are navigating.

The mappings below describe the menu bar surface.

Priority is a Checkvist client, so the gestures worth keeping are Checkvist's.
`j` `k` and the arrows, `Space` and `Shift+Space`, `Enter` and `Shift+Enter`,
`Tab` and `Shift+Tab`, `Shift+←` / `Shift+→` for hoisting, `⌘↑` / `⌘↓` to move,
`Del`, `F2`, `1`–`9` and `0`, `/`, and the `dd` `dr` `gg` `sc` sequences all mean
what they mean there. So does `?`.

Where it can't match, it's for one reason: Checkvist spells most of its actions
as two-letter sequences (`td`, `tt`, `ct`, `hf`, `ll`, `ee`, `nn`, `uu`), and
Priority spends those same starter letters on single-key root tabs
(`q w e r t y u`) and filter slots (`z x c v b n ,`). A letter can be a sequence
starter or a shortcut, not both — pressing it has to either act or wait for a
second key. The tabs won, because switching view is the thing you do most.

The nearest equivalents:

| Checkvist | Here | |
| --- | --- | --- |
| `td` schedule for today | `dt` | `t` is the Kanban tab |
| `tt` tags | `gt` | `t` is the Kanban tab |
| `ct` clear tags | `gu` | `c` is a filter slot |
| `hf` hide future | `Shift+H` | `h` collapses |
| `ll` go to a list | `Shift+L` | `l` expands |
| `ee` / `ea` / `ei` edit | `F2` / `a` / `i` | `e` is the Tags tab |
| `uu` undo | `Cmd+Z` | `u` is the Daily tab |
| `om` distraction-free | `'` | focus session |

All of them are rebindable in `Preferences → Keybindings` if you'd rather have
the Checkvist spelling than the tab.

### Integrations

| Key | Action |
| --- | --- |
| `o` | Open the selected task in Obsidian |
| `O` | Open in a new Obsidian window |
| `gc` | Add to Google Calendar |

### Scope

Every view except **All** answers the same question the same way: does it show
only this level, or everything below it? One toggle decides — `toggle children`,
or the chip in the breadcrumb bar, which also says which answer is in force.

All is the exception on purpose. It's the navigator you drill through to *set*
the scope the other views read, so it's always strictly parented.

## Focus

Focus is where the app opens, because the first question it exists to answer is
what to do next rather than what there is. `Cmd+8` from anywhere in the window
takes the main pane; `Esc` gives it back. The preference **Open on the focus
screen** turns the launch behaviour off without hiding the screen.

The pane has two states and no third surface. With nothing running it is the
**ladder**: one task at a time at full size, the ones you have climbed past
stacked and shrunken above it, with the reason each was offered written under
its title. Once a block starts, the same pane *is* the block — the task, a
clock, and the four things you can do to it.

| Key | Action |
| --- | --- |
| `↑` / `↓` | Climb the ladder. `k` / `j` do the same |
| `⌥↑` / `⌥↓` | Reorder within the same urgency, rather than moving the cursor |
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
due date is only a fact. Press a
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

Open with `:`, `;`, `Cmd+K` — or a **double-tap of Shift**, as in Checkvist. A
modifier on its own produces no key-down event, so `⇧⇧` is recognised as a
gesture rather than bound as a shortcut; Shift held for a capital letter counts
as a chord rather than a tap, so typing never trips it. Most commands accept several spellings — `unrepeat`, `no repeat`, `remove repeat` and `clear repeat` all do the same thing.

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

## Views

| View | Key | What it shows |
| --- | --- | --- |
| **All** | `q` | The full tree |
| **Due** | `w` | Due and overdue, soonest first |
| **Tags** | `e` | Grouped by tag |
| **Priority** | `r` | Your ranked queue |
| **Kanban** | `t` | Configurable columns, optionally in a row per goal |
| **Matrix** | `y` | Eisenhower quadrants by importance and urgency, with what is still unplaced a keypress away underneath |
| **Daily** | `u` | Dailies, the chart, and what you finished |

Kanban cards show the task text with tags stripped, a `P1`–`P9` priority badge, the due date with overdue/today highlighting, inline tags, and a subtask count. Columns are configured in Preferences and reorder by drag. Cards drag between and within columns; a hairline marks where the card will land.

A column is defined by one or more conditions, and claims a task if it matches **any** of them. Columns are evaluated in order, so a task lands in the first one that claims it.

| Condition | Claims |
| --- | --- |
| Tag | Tasks carrying `#tag` |
| Due bucket | Overdue, ASAP, Today, Tomorrow, Next 7 days, … |
| Matrix quadrant | Whatever sits in Do / Schedule / Delegate / Eliminate |
| Priority rank | `P3 or higher` claims P1, P2 and P3 |
| Has no subtasks | Only the leaves — the things you actually do, not the goals above them |
| Not on the matrix | The board's own inbox: everything still unplaced |
| Everything else | Whatever no earlier column took |

Each column header carries its card count. Give a column a **WIP limit** and the count reads `4/3` and turns amber when it's over — advisory only, nothing is ever blocked.

`kanban swimlanes` turns the board into a **row per top-level goal**, columns per state. A single row of columns tells you what state a task is in but never what it's *for*; with a tree that's mostly goal structure, that's the more useful axis. Every lane draws all its columns, including the empty ones — that emptiness is the comparison.

Dropping a card into a quadrant column places it on the matrix, the same write the Matrix view's drop makes. Columns defined only by priority, leafness or matrix-absence describe a task rather than ask something of it, so they accept no drops.

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

The menu bar panel is the point of this app, but it dismisses on any outside
click and it is 400pt wide — which is right for a glance and wrong for half an
hour of reorganising, and leaves nowhere to look when something breaks. So the
same seven views also open in an ordinary window.

Open it from **the status item's menu → Open Main Window**, from the
command palette (`window`), or with `Cmd+0` once it is up. It is resizable,
survives clicking away, remembers its frame, and every keybinding works in it
exactly as it does in the panel — `Esc` cancels what you are typing but leaves
the window alone.

**Everything is shared.** One list, one cursor, one selected view, in both
places at once: change tab in the window and the panel changes too. That is a
deliberate limit rather than an oversight — the visible task list is derived
from the tab, the cursor and the search text, so two surfaces showing different
tabs would need two of everything underneath.

**A Dock icon appears while the window is open** and goes again when you close
it. That is what buys you `Cmd-Tab`, `Cmd-W`, `Cmd-Q` and — the one you notice
if it is missing — an Edit menu, without which copy and paste do nothing in the
quick-add field.

The toolbar carries a **list switcher**: the current list by name, every list
you have, the offline workspace, and a Refresh. Switching here does the same
full switch `Shift+L` and `list <name>` do — the cursor resets, the kanban
filter clears, and the pending offline queue for the list you left is not
carried into the one you arrived at.

## Diagnostics

`⚕` in the window's toolbar or its dock row, `diagnostics` in the palette, or
**View → Diagnostics**. It answers "why does this look wrong?":

- **Status** — connection, current list, network, sync age, open task count, and whether anything is queued offline.
- **Health** — a green tick or an orange triangle per integration, with the detail underneath. The AFFiNE row lists every path it searched for the helper; the MCP row shows the resolved command; the Google Calendar and Google Tasks rows show whether the shared Google sign-in covers them.
- **Recent problems** — every failure this session, timestamped. Worth having because nothing else keeps one: the error line is overwritten by the next thing that fails, the status message erases itself after three seconds, and integration errors were not retained at all. Not written to disk — it covers this run of the app, not last fortnight's.
- **Data** — where everything lives, with a Reveal button each, including `~/.config/priority/config.json`, which belongs to the CLI rather than the app and is a recurring source of confusion.

**Copy Report** and **Export Report…** produce plain text you can paste into an
issue. Both run it through a redactor first: anything labelled like a
credential, and any bare token-shaped run, comes out as `<redacted>`. Check it
before you post it anyway.

## The dock row

A narrow strip along the bottom, in every view. Right to left:

| Button | Does |
| --- | --- |
| ⚙︎ Gear | Preferences |
| ↻ Refresh | Re-fetch from Checkvist, with a spinner while it runs |
| ↕ Resize | Reveal the drag strip — **panel only**, a window has a resize corner |
| ⚕ Diagnostics | Open the diagnostics sheet — **window only** |
| ▁▃▅ Graph | Show/hide the Daily chart — **Daily view only** |

In the window the row also carries a sync readout on the left — "Synced 4m ago",
"Offline · changes queued", or whatever last failed.

**Each root view remembers its own height.** The Daily view stacks a checklist, a chart and a completions list where the All view is a single list, so one shared height would be wrong for one of them at all times. Drag the strip to set a height; double-click it to go back to sizing from the content.

Heights are clamped to 240–900pt on write *and* on read at launch, so a stored value can never put the strip out of reach. If one somehow does:

```bash
defaults delete uk.co.maybeitsadam.priority panelHeightOverridesByRootView
```

Hiding the graph shortens the panel by exactly the chart's height, which turns the Daily view into a compact checklist on days you're only ticking things off.

## Daily log

The Daily view (`u`) answers "what did I get done, and how does today compare?"

### Dailies

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
- **The day's plan is derived, not authored.** At the first popover open after your rollover hour, whatever is due, overdue or starting that day is snapshotted. That's what the day's note measures its "N of M planned left" against — you never plan a day by hand.
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
