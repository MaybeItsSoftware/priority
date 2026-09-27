# CLI Guide

`priority` is a Rust command-line tool for the same data the app works with:
your local workspace (folders, lists and tasks), your Checkvist lists, your
dailies, and your day log.

It is a peer of the app rather than a remote control for it. It talks to the
Checkvist API directly and reads and writes Priority's local files off disk, so
every command works whether or not the app is running. The writes take the same
locks the app does, so both can be open at once.

```bash
./scripts/install_cli.sh     # builds release and links `priority` onto your PATH
priority --help
```

Or without installing:

```bash
cargo build --release --manifest-path cli/Cargo.toml
cli/target/release/priority dailies
```

## The terminal UI

Run `priority` with no arguments and it opens a terminal UI with the same tabs
as the menu bar app, and the same keys to reach them.

```
 All q │ Due w │ Tags e │ Priority r │ Kanban t │ Matrix y │ Daily d
┌ All ───────────────────────────────────────────────────────────────┐
│▎▾ [ ] Ship v0.4                                                    │
│   ▸ [ ] Draft the release notes  #work                             │
│     [x] Tag the commit                                             │
│   ▸ [ ] Buy milk  #home                                            │
└────────────────────────────────────────────────────────────────────┘
 j/k move · l/h open-shut · ] [ zoom · space done · a add · ? help · esc quit
```

Tasks start shut. `l` opens one and its subtasks appear indented underneath;
`▸` marks a task with something behind it and `▾` one that's open. What's open
is remembered per list between runs, in `outline.json` beside the config file —
separately from the app, which keeps its own.

| Key | Action |
| --- | --- |
| `q` `w` `e` `r` `t` `y` `d` | Jump to All, Due, Tags, Priority, Kanban, Matrix, Daily |
| `tab` / `shift-tab` | Cycle tabs |
| `j` `k` or `↓` `↑` | Move |
| `l` `h` or `→` `←` | Open / shut a task's subtasks, then step in and back out |
| `]` `[` | Zoom the list into the selected task, and back out (All tab) |
| `space` | Complete a task, reopen a closed one, or tick a daily |
| `u` | Reopen |
| `x` | Mark "won't do" |
| `a` | Add a task — or a daily, on the Daily tab |
| `F5` / `ctrl-r` | Refresh from Checkvist |
| `?` | Help |
| `esc` | Quit |

The letters were the app's menu bar panel's, not a new set: `q` was its All view,
so it is the All tab here too. That means **`q` does not quit** — `esc` does.
The panel itself has been removed from the app; these letters outlived it.

Each tab shapes the same data differently:

- **Due** groups into overdue / today / later.
- **Tags** groups by tag, with the untagged kept together.
- **Priority** reads the ranks you set in the app with `1`–`9`, absolute queue
  first and then per-parent.
- **Kanban** uses the columns you configured in the app, evaluated in order — a
  task belongs to the first column it matches, and a catch-all column takes only
  what the others left. The due-date bucketing is a port of the app's
  `classifyDueBucket`, so the board agrees with the app's own
  bucketing rather than approximating it.
- **Matrix** splits the Eisenhower placements into DO / SCHEDULE / DELEGATE /
  ELIMINATE, at zero on each axis. A task sitting at the origin has not been
  judged, so it is left out rather than filed under "eliminate".
- **Daily** shows your dailies, the day's counts, and what you finished.

Adding a task while you are inside a subtask puts it there, as quick-add does in
the app. Kanban and Matrix are read-only views of state the app owns: you can
complete a task from them, but the column and quadrant are set in the app.

**Without Checkvist credentials the Daily tab still works in full** — it reads
local files — and the other six explain what is missing rather than failing.

Every key that changes something dispatches the same tool call an assistant
would make over MCP, so the terminal cannot do anything the other front ends
can't, or do it differently.

It needs an interactive terminal: `priority | cat`, or a cron job, gets a clear
error pointing at `--help` rather than a UI nobody can quit.

## Signing in

```bash
priority auth login
```

It prompts for your Checkvist email and your remote key (from
[checkvist.com/auth/profile](https://checkvist.com/auth/profile), read without
echo), checks them against the API, and only then writes them to
`~/.config/priority/config.json` with mode 0600. A mistyped key fails at this
point rather than as a puzzling 401 on some later command.

```
priority auth status        where the config lives and what is in effect
priority auth set-list ID   the default list, used when --list-id is omitted
priority auth logout        forget the key; --all deletes the file
priority auth path          just the path, for scripts
```

`auth status` never prints the remote key — only its length, which is enough to
spot a truncated paste.

### These credentials are the CLI's own

Signing in here does not sign you in to the Priority app. The invariant runs
one way: the CLI never reads the app's keychain. That is deliberate. The app
keeps its remote key in the login keychain, where it is reachable only by
something carrying the app's code signature; a CLI that depended on it would
work or not depending on how the app happened to be built and signed that day.
Its own file is predictable, portable, and works on a machine with no app
installed.

The other direction is allowed, and is how the app sets up an MCP client: it
writes its credentials *into* this file, then generates a client config that
carries no secret at all. Nothing about that makes the CLI depend on the app —
the file it reads is the same one `auth login` writes, whoever put it there. If
you signed in here as a different account, setting up an MCP client from the
app will overwrite `username` and `remote_key`; that only happens on an
explicit action in the app's settings. See `docs/mcp-server.md`.

The trade is that the key sits in a plain file rather than the keychain, as CLI
credential files conventionally do. It is created mode 0600 from the moment it
exists — not chmod-ed afterwards, since the gap between the two is a window in
which it is world-readable.

### Environment variables still win

- `CHECKVIST_USERNAME`, `CHECKVIST_REMOTE_KEY`, `CHECKVIST_LIST_ID`
- `CHECKVIST_BASE_URL` — defaults to `https://checkvist.com`
- `PRIORITY_MCP_STORE_DIR`, `PRIORITY_MCP_PREFS_PATH` — where the local
  files are read from
- `PRIORITY_CONFIG_PATH`, or `XDG_CONFIG_HOME` — where the config file itself
  lives

Any of these set in the environment beats the file, so an MCP client config that
passes credentials keeps working untouched, and `CHECKVIST_LIST_ID=999 priority
tasks` is a one-off override. `auth status` says which source each value came
from, and the auth commands warn you when a variable is shadowing what they just
wrote.

The dailies, day-log and metadata commands read local files and need no
credentials at all, so they work before you have signed in to anything.

### Editing the file by hand

```json
{
  "username": "you@example.com",
  "remote_key": "...",
  "list_id": "945183",
  "base_url": "https://checkvist.com",
  "store_directory": "~/Library/Application Support/Priority"
}
```

Every key is optional. `~` is expanded in the path keys. A missing or malformed
file is treated as an empty config rather than an error — `priority dailies`
has no business failing over a credential file it never consults.

`store_directory` defaults to the app's own location, and that default is the
one place the CLI and the app are deliberately joined: reading the dailies and
day log the app writes is the whole reason those commands exist. Point it
elsewhere for a CLI-only setup.

## Commands

```
  lists       List your non-archived checklists
  new-list    Create a new checklist
  tasks       Show a list's tasks as a tree
  search      Search a list by content, tag and/or due date
  add         Add a task
  update      Change a task's content and/or due date
  note        Append a note to a task
  move        Reorder a task among its siblings. Position is 1-based
  reparent    Move a task under a different parent, or to the list root
  done        Complete a task
  reopen      Reopen a completed task
  invalidate  Mark a task "won't do"
  rm          Delete a task
  log         What actually happened on recent days
  dailies     Show your dailies with today's schedule and tick state
  daily       Create, change or tick a daily
  metadata    Priority's own state: ranks, recurrence, start dates, matrix, board
  ws          The app's local workspace: folders, lists and tasks (alias: workspace)
  focus       What the focus timer is doing
  focused     Focused time already recorded
  auth        Store, check or clear this CLI's Checkvist credentials
  mcp         Run as an MCP stdio server
  tools       List the tools this binary exposes
  call        Call a tool by name with raw JSON arguments
```

Two global options: `--list-id` and `--json`. `--json` prints the raw payload
instead of the rendering, which is the same JSON the MCP tool of that name
returns — useful for `jq`, and for checking what an assistant would have seen.

### Examples

```bash
priority lists
priority tasks                             # the default list, open tasks, as a tree
priority tasks --all                       # include closed and "won't do"
priority search -q report --due-before 2026-09-01
priority search -t work --limit 10

priority add Draft the release notes --due friday
priority add Check the numbers --parent 12345
priority note 12345 Waiting on the design review
priority done 12345

priority log --days 7
priority dailies
priority daily add Read for twenty minutes --weekdays mon,wed,fri
priority daily add Water the plants --every-days 3
priority daily tick 5F385C47-E2A6-488E-B3E1-84B0511FFAD4
priority daily update <id> --every-days 4
priority daily update <id> --weekdays weekdays   # back off the cycle
priority daily update <id> --archive

priority --json dailies | jq '.dailies[] | select(.done | not)'
```

`--weekdays` takes what you would actually type: `mon,wed,fri`, `weekdays`,
`weekend`, `every day`, or `Calendar` numbers where 1 is Sunday. The numbers are
what everything downstream sees; the spellings exist only at this boundary.

`--every-days N` is the other kind of schedule: a cycle that rotates through the
week rather than sitting on fixed days, counted from the day you set it. The two
are alternatives — passing both is refused rather than silently resolved — and
`--weekdays` on an existing cycle ends it, restoring the days it had before.

### The local workspace

`priority ws` works on the tree the app shows, in
`~/Library/Application Support/Priority/priority.sqlite`, not on Checkvist. Its
ids are the workspace's UUIDs, and `ws tree` / `ws tasks` print them beside
every row. The global `--list-id` is a Checkvist id and is ignored here.

```bash
priority ws tree                                   # folders, lists, nested lists
priority ws tasks <LIST_ID>                        # a list's open tasks as a tree
priority ws tasks <LIST_ID> --all --parent <TASK_ID>

priority ws add Read the paper --list <LIST_ID> \
  --link 'obsidian://open?vault=Studies&file=Paper' -c this-week
priority ws add Section 3 --parent <TASK_ID> -n "Start with the proofs"
priority ws update <TASK_ID> --title "Read the paper twice" --link https://example.com
priority ws update <TASK_ID> --no-links
priority ws update <TASK_ID> --kind list --pin      # nested list, pinned to the sidebar
priority ws done <TASK_ID>
priority ws move <TASK_ID> --parent <TASK_ID>       # the subtree comes too
priority ws move <TASK_ID> --list <LIST_ID> --position 1
priority ws to-list <TASK_ID> --folder <FOLDER_ID>  # promote to its own list
priority ws new-folder Computer Science
priority ws new-list Revision --folder <FOLDER_ID>
priority ws move-list <LIST_ID> --folder <FOLDER_ID>
priority ws rm <TASK_ID>
```

These write while the app is open. Each command is one step in the app's Undo
menu, labelled "MCP: …", and the app picks the change up within about a
second. `docs/mcp-server.md` explains how that is made safe. The one thing
refused is completing a repeating task, since only the app can schedule its
next occurrence.

### The escape hatch

Every command is one of the MCP tools under a friendlier name. If you want the
tool directly:

```bash
priority tools
priority call daily_add '{"title": "Stretch", "active_weekdays": [2,4,6]}'
priority call task_search '{"query": "invoice", "include_closed": true}'
```

This is not a fallback for missing features — it is the same dispatch table the
subcommands go through. It exists so that a tool argument the CLI has no flag
for is still reachable, and so `priority call` can be used to reproduce exactly
what an assistant did.

## As an MCP server

This binary *is* Priority's MCP server. There is no other — the app ships a copy
at `Priority.app/Contents/Helpers/priority` and `Priority --mcp-server` hands
the process over to it (`Priority/MCPServerShim.swift`).

```bash
priority mcp
priority --mcp-server     # accepted too, so a config written for the app works unchanged
```

That second spelling is load-bearing rather than a convenience: MCP client
configurations written before the app bundled this binary say
`/Applications/Priority.app/Contents/MacOS/Priority --mcp-server`, and they
keep working because both the flag and the environment-first credential rule
below were already here.

If you have run `auth login`, no `env` block is needed at all:

```json
{
  "mcpServers": {
    "priority": {
      "command": "/Users/you/.local/bin/priority",
      "args": ["mcp"]
    }
  }
}
```

Passing credentials in `env` still works and still takes precedence, which is
what makes an existing configuration keep behaving identically — the config file
can never override what a client already supplies.

See `docs/mcp-server.md` for the tool list and the history of how three
implementations became one.

## Editing dailies while the app is open

Both processes edit `dailies.json` and `daylog.jsonl`, and both go through the
same `flock(2)` on the same sibling `.lock` file, so a write from here cannot
interleave with one from the app. The CLI also re-reads the file inside the lock
rather than saving a snapshot it loaded earlier, which is what stops a
concurrent write being silently erased.

The app watches its store directory, so a daily added here appears in the app
without a relaunch.

What is *not* writable from here is `metadata` — priority ranks, recurrence
rules and start dates. Those live in `UserDefaults`, which the running app holds
in memory and rewrites on its own schedule, so there is no file lock that would
let an external write survive. Setting them has to go through the app.

## Layout

```
cli/
  Cargo.toml
  src/
    main.rs       entry point; --mcp-server is intercepted before argument parsing
    cli.rs        subcommands, the auth commands, and the renderings
    tools.rs      the tools, implemented once
    checkvist.rs  the API client
    config.rs     ~/.config/priority/config.json, and the environment-first rule
    local.rs      dailies, day log, and preferences, off disk
    lock.rs       flock(2), on the same lock files the app takes
    workspace.rs  the app's database, read-only: the focus timer and its history
    workspace_tasks.rs  the app's database, read and written: folders, lists, tasks
    mcp.rs        the JSON-RPC stdio server and the tool schemas
    tests.rs      unit tests
    workspace_tests.rs  the workspace writes, against scratch copies of the real schema
    fixtures/workspace_schema.sql  that schema, from scripts/dump_workspace_schema.sh
```

`cli.rs` and `mcp.rs` are both front ends onto `tools.rs`. Neither implements a
tool, so the CLI and the MCP server cannot drift apart — a command that cannot
be expressed as a tool call does not belong in `cli.rs`.

The crate is deliberately outside both `Package.swift` and the Xcode project: it
shares no source with them, and nothing in `Priority/` should ever `import` it.
The app *runs* it — `scripts/bundle_cli.sh`, from an Xcode build phase, cargo-
builds it and installs it into the bundle — but that is a process boundary, not
a source dependency. One consequence worth knowing: **building the app needs
cargo.** `PRIORITY_SKIP_CLI_BUNDLE=1` opts out, and produces an app with no MCP
server.

## Developing

```bash
cargo test --manifest-path cli/Cargo.toml
cargo clippy --manifest-path cli/Cargo.toml --all-targets -- -D warnings
cargo fmt --manifest-path cli/Cargo.toml --check
python3 scripts/mcp_smoke_check.py       # needs a Debug app build
```

`cargo test` is what covers the server's behaviour, now that there is only one
implementation of it. The smoke check covers the seam instead: that
`Priority --mcp-server` still reaches this binary, and that a configuration
written before the migration still gets a working server. CI runs all four.
