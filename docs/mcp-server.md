# MCP Server Guide

Priority ships an MCP stdio server so an AI assistant can work directly with your Checkvist data.

- Server command: `priority mcp` — the CLI, which the app ships at
  `Contents/Helpers/priority`. `Priority --mcp-server` also works and hands over
  to it; see [One server, two ways to name it](#one-server-two-ways-to-name-it)
- Transport: stdio, newline-delimited JSON — one JSON-RPC object per line, as the
  MCP stdio transport specifies. LSP-style `Content-Length` framing is also
  accepted, and replies mirror whichever framing the client used.
- Dependencies: none beyond Priority itself — the server ships inside the app

## What It Can Do

The server exposes 21 MCP tools, in two groups.

**Checkvist tools** — these reach the Checkvist API directly, so they work
whether or not the app is running:

| Tool | What it does |
|---|---|
| `task_lists` | List non-archived checklists |
| `list_create` | Create a checklist |
| `task_fetch` | Fetch a list's tasks (open only by default) |
| `task_search` | Filter by content substring, tag, and/or due date |
| `task_add` | Quick-add at the root or under a specific parent |
| `task_update` | Change content and/or due |
| `task_note_add` | Append a note (a Checkvist comment) |
| `task_move` | Reorder among siblings (1-based position) |
| `task_reparent` | Move under a different parent, or to the root |
| `project_move` | Move a root task and its full subtree to another list, with an old-to-new ID map |
| `task_complete` | Close a task |
| `task_reopen` | Reopen a task |
| `task_invalidate` | Mark "won't do" |
| `task_delete` | Delete a task |

**Local tools** — these reach the state Priority keeps on this machine, which
Checkvist has no representation for:

| Tool | What it does | |
|---|---|---|
| `daily_log_fetch` | What happened on recent days: completions, focus time, unfinished/deferred tasks, daily ticks | read |
| `dailies_list` | Configured dailies with today's schedule and tick state | read |
| `task_metadata` | Priority ranks (scoped and absolute), recurrence rules, start dates, Eisenhower urgency/importance, kanban columns | read |
| `task_matrix_set` | Eisenhower urgency/importance, in batches | write, **only while the app is closed** |
| `daily_add` | Create a daily | write |
| `daily_update` | Rename, reschedule, archive/unarchive a daily | write |
| `daily_tick` | Tick or un-tick a daily for today | write |

Notes:

- The Checkvist tools talk directly to the Checkvist API.
- It does not automate the local macOS app UI.
- `task_add` supports both root insertion and specific parent insertion.
- The local tools need no IPC. They read the app's preferences plist by bundle
  id and the day-log files at the same Application Support path, under the same
  `flock` protocol the app uses.
- `task_metadata` is read-only, and stays that way. Priorities, recurrence and
  start dates live in `UserDefaults`, which the running app holds in memory and
  rewrites on its own schedule — there is no equivalent of the file lock below
  that would let an external write survive. Setting those has to go through the
  app.
- `task_matrix_set` is the one narrow exception, and it does not disprove the
  rule above so much as work around it. It refuses outright while Priority is
  running (`pgrep -x Priority`), and writes through `defaults write` rather than
  the plist file, so `cfprefsd` stays the single owner of the store. Both halves
  are load-bearing: a direct file write is invisible to `cfprefsd` and gets
  overwritten by its cached copy, and a write of any kind made while the app is
  running is discarded the moment the user places one task by hand.

  It exists because the alternative was placing two hundred tasks by hand. A
  bulk first pass from an assistant, corrected afterwards in the app, is a
  different job from "set this one task's urgency" — which still goes through
  the app, as above.

### How the daily writes stay safe

Two processes edit `dailies.json` and `daylog.jsonl`: the app and this server.
Three things make that safe, and all three are load-bearing:

1. **A file lock.** `FileLock` (`Sources/PriorityCore/FileLock.swift`) takes `flock(2)` on a
   sibling `.lock` file — a sibling, because saves are atomic (temp + rename) and
   replace the data file's inode, so a lock held on it guards nothing. The CLI
   takes the same lock on the same path, so the two genuinely exclude each
   other.
2. **Read/modify/write, never save-a-snapshot.** `DailyDefinitionsStore.mutate`
   re-reads inside the lock and applies the change to what is on disk *now*. The
   app used to write its launch-time copy back wholesale, which silently erased
   anything added since. A mutation must be expressed as *what changed*.
3. **A directory watcher.** `DailyLogService` watches the store directory (not
   the files — the rename would orphan a file watch) and reloads, so a daily
   added here shows up in the popover without a relaunch.

The serialised format is therefore a cross-process interface. Two constraints
are pinned by `DailyDefinitionsStoreFormatTests`:

- Dates are `yyyy-MM-ddTHH:mm:ssZ` with **no fractional seconds**. The Swift
  decoder is `.iso8601`, which rejects them, and `load()` turns a decode failure
  into an *empty* collection — so one bad timestamp makes every daily vanish and
  the next save persists that emptiness.
- `activeWeekdays` is written sorted, so saves don't churn the file.

A daily is scheduled *either* on weekdays *or* on a cycle. `intervalDays` (with
`intervalAnchor`, a day the cycle lands on) is present only for the second kind
and takes over from `activeWeekdays` entirely — the weekday set stays on the
record so that ending the cycle restores it. Both fields are absent on every
daily written before cycles existed, which decodes as the weekday case. In the
tools this is `interval_days`: passing it alongside `active_weekdays` is refused
rather than resolved in favour of whichever the implementation checks first, and
passing `active_weekdays` to `daily_update` clears an existing cycle.

### One server, two ways to name it

There is one implementation: the `priority` CLI (`cli/src/mcp.rs`). The app
**ships** it, at `Contents/Helpers/priority`, installed during the build by
`scripts/bundle_cli.sh` and signed with the app.

| Command | What happens |
|---|---|
| `priority mcp` | The server, directly. What newly written configurations use. |
| `Priority --mcp-server` | `MCPServerShim` `execv`s the bundled helper. What configurations written before this change say. |

Because the app bundles the CLI, `Priority --mcp-server` works on a machine
where the CLI was never installed separately — which is what made retiring the
old server safe.

There used to be a second implementation: 1,760 lines of Swift in
`Priority/Plugins/MCP/MCPServer.swift`, running in-process. A third, a bundled
`python3` fallback script, went earlier. Both existed for the same reason — a
client might be pointed at any of them — and both cost the same thing: every
tool change was a two- or three-way edit, and every divergence a two- or
three-way diff. They were held equal from the outside by
`scripts/mcp_parity_check.py`, which drove each over stdio and compared tool
lists, answers, files written, and HTTP requests, because neither could import
the other.

What kept the Swift one alive was never a capability the CLI lacked; the parity
check proved that every one of the nineteen tools agreed. It was that MCP client
configurations already written to users' disks name
`/Applications/Priority.app/Contents/MacOS/Priority --mcp-server`. Bundling the
CLI and turning that path into a shim removed the reason, so:

- ~1,760 lines of Swift are gone, as is ~610 lines of parity harness and a CI
  job;
- there is one implementation to be correct rather than two to keep equal;
- and existing configurations keep working untouched, because the CLI already
  accepted the bare `--mcp-server` flag (`cli/src/main.rs`) and already reads
  credentials from the environment ahead of its own config file
  (`cli/src/config.rs`) — which is exactly where a client configuration written
  back then put them.

`cargo test` covers the server. `scripts/mcp_smoke_check.py` covers the seam:

```bash
python3 scripts/mcp_smoke_check.py   # needs a Debug app build
```

It drives both spellings above and checks they answer `initialize` and expose
the same nineteen tools — in particular that an old-style invocation, with
credentials in `env`, still reaches a working server. It reads no real data and
needs no Checkvist credentials.

## Setup (the short version)

**Preferences → Plugins → Native MCP Integration.** Enable the toggle and the page
walks three steps:

1. **Checkvist connected** — the server signs in with your Checkvist credentials,
   so setup is blocked until they exist: the client buttons are disabled without
   them, and the coordinator refuses as well rather than trusting a UI guard.
   There would be nothing to hand the server, and every tool call would fail
   inside your AI client, a long way from the app. Once they exist, setting up a
   client copies that login down into the CLI's own store — see
   [Configuration](#configuration).
2. **Server command found** — the path to the executable an MCP client launches.
   Press Refresh after moving the app.
3. **Add to an AI client** — one button per client detected on this machine.

Priority detects Claude Code, Claude Desktop, Cursor, Windsurf, VS Code, and
Zed. What the button does depends on the client, because the wrong route is worse
than no route:

| Client | Action | Why |
|---|---|---|
| Claude Desktop, Cursor, Windsurf, VS Code | Writes the config file | Plain JSON files that hold nothing but MCP config |
| Claude Code | Copies a `claude mcp add-json` command to run | Claude Code rewrites `~/.claude.json` constantly; editing it underneath would race |
| Zed | Copies a snippet to paste | `settings.json` carries comments that a JSON rewrite would delete |

Direct writes **merge**: your other MCP servers and every unrelated key survive.
If the existing file isn't valid JSON, Priority refuses rather than replacing
it. Keys come back sorted, so expect the file to be reformatted once.

Config writes go straight to the client's file — release builds are not
sandboxed (see `Priority.release.entitlements` for why), so no folder-access
prompt is involved. A client config Priority creates from scratch is tightened
to mode 0600; one that already existed keeps the mode its owner chose.

Before it writes or copies anything, setup seeds the CLI's credential store: it
merges your username and remote key into `~/.config/priority/config.json`,
creating `~/.config/priority` at mode 0700 and the file at 0600. It merges
rather than replaces, so a `base_url` you set by hand for a self-hosted
Checkvist survives, and it only fills `list_id` when that key is absent — the
generated MCP entry already names the default list per client, so the CLI's own
default for terminal use is left alone. Nothing happens to the file when it
already says this.

If nothing is detected, use **Copy Client Config** and paste it in by hand — the
rest of this guide covers that.

## Configuration

The server signs in to Checkvist itself, so it needs a username and a remote
key. They can come from a file or from the environment, and the order is the
conventional one: **the environment beats the file, and a variable set in the
environment means the file is not consulted for that value at all**
(`cli/src/config.rs`).

### Credentials in the CLI's own store (recommended)

Keep them in `~/.config/priority/config.json` and leave the client config
credential-free. Two ways to put them there, and they write the same file:

- **From Priority.** Setting up a client, or pressing **Copy Client Config**,
  seeds the file first and then hands the client an entry with no secret in it.
- **From the terminal.** `priority auth login` prompts for both, checks them
  against the API before writing, and creates the file at mode 0600. See
  `docs/cli.md` for that command and its `auth status` / `auth set-list`
  siblings.

Either way there is one copy of the key on this machine, and every client that
launches the server reads it — which is the point.

### Environment variables (the override)

Set on the MCP process, usually through an `env` block in a client config:

- `CHECKVIST_USERNAME`
- `CHECKVIST_REMOTE_KEY`
- `CHECKVIST_LIST_ID` (default list)
- `CHECKVIST_BASE_URL` (defaults to `https://checkvist.com`)

Setting one of these means the config file is **not read for that value** — not
merged with, not fallen back to. That is right for a one-off override, for CI,
and for `scripts/mcp_smoke_check.py`, which drives the server with credentials
in the environment precisely so it cannot pick up whatever the developer
happens to have configured. `PRIORITY_CONFIG_PATH` (or `XDG_CONFIG_HOME`) moves
the file itself, for the same reason.

It is the wrong tool for a client config you intend to keep, because that pins
the key: see below.

### Rotating your remote key

A remote key baked into a client's `env` block is a second copy of it, and the
client goes on presenting the old one until someone edits that file by hand —
as a 401 from inside the AI client, with nothing in Priority saying why.

With credentials in the CLI's store there is one copy, so rotation is: change
the key in Priority and set the client up once more (which re-seeds the file),
or run `priority auth login` again. Every configured client follows, because
they all read the one file. If any client config still carries the key in
`env`, that entry keeps using the pinned value until you replace it — setting
that client up again from Priority rewrites the entry into the credential-free
form.

### Choosing a list

If `CHECKVIST_LIST_ID` is not set — by the client entry Priority generates, by
your own `env` block, or by `list_id` in the config file — pass `list_id` in
tool calls that need a list.

### Finding the server command

Command resolution priority, used both by the settings pane when it generates a
config and by `MCPServerShim` when `--mcp-server` looks for something to run:

1. `PRIORITY_MCP_EXECUTABLE_PATH` (explicit override — point a development build
   at a freshly built CLI without reinstalling the app)
2. The bundled helper: `/Applications/Priority.app/Contents/Helpers/priority`,
   then the same path relative to the running bundle
3. A separately installed CLI: `~/.local/bin`, `~/bin`, `/usr/local/bin`,
   `/opt/homebrew/bin`

If none resolves, a generated config points at
`/Applications/Priority.app/Contents/Helpers/priority` so it is obvious what to
fix, and `--mcp-server` exits with the list of paths it tried on stderr, where
the client will log it.

Extra control env vars:

- `PRIORITY_MCP_GUIDE_PATH` to override guide detection

## Run Manually

Once credentials are in place — `priority auth login`, or any client set up from
Priority's settings:

```bash
'/Applications/Priority.app/Contents/Helpers/priority' mcp
```

To override them for one run, without touching the stored ones:

```bash
CHECKVIST_USERNAME="you@example.com" \
CHECKVIST_REMOTE_KEY="your-remote-key" \
CHECKVIST_LIST_ID="123456" \
'/Applications/Priority.app/Contents/Helpers/priority' mcp
```

It will wait for an MCP client to connect over stdio.

## Client Config Example

Most MCP clients accept a JSON config similar to this — which is what Priority
generates now, carrying a default list and no credentials:

```json
{
  "mcpServers": {
    "priority": {
      "command": "/Applications/Priority.app/Contents/Helpers/priority",
      "args": ["mcp"],
      "env": {
        "CHECKVIST_LIST_ID": "123456"
      }
    }
  }
}
```

With no default list set, the `env` block is omitted entirely rather than
written empty:

```json
{
  "mcpServers": {
    "priority": {
      "command": "/Applications/Priority.app/Contents/Helpers/priority",
      "args": ["mcp"]
    }
  }
}
```

Use your own app path. If you are writing this by hand rather than letting
Priority write it, run `priority auth login` first — there is nothing in the
config that would sign the server in.

A configuration written before the CLI was bundled names the app binary
instead, and one written before credentials moved out of `env` carries them
inline:

```json
{
  "mcpServers": {
    "priority": {
      "command": "/Applications/Priority.app/Contents/MacOS/Priority",
      "args": ["--mcp-server"],
      "env": {
        "CHECKVIST_USERNAME": "you@example.com",
        "CHECKVIST_REMOTE_KEY": "your-remote-key",
        "CHECKVIST_LIST_ID": "123456"
      }
    }
  }
}
```

That still works in both respects, so there is nothing you have to change: the
app hands the process to the bundled helper, and the environment still beats the
file, so those inline credentials are the ones the server uses. The one thing to
know is that they are pinned — rotating your remote key means editing this file
too, or setting the client up again from Priority, which regenerates the whole
entry in the credential-free form above.

A separately installed CLI works too, if you have run `scripts/install_cli.sh`:

```json
{ "mcpServers": { "priority": { "command": "/usr/local/bin/priority", "args": ["mcp"] } } }
```

## Suggested First Calls

1. `task_lists`
2. `task_fetch` (omit `list_id` if default is set)
3. `task_add` with `location: "default"` and sample content
4. `task_add` with `location: "specific"` and `parent_task_id`
