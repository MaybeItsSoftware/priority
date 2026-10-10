# AFFiNE Integration

Takt keeps a **two-way checklist** in an [AFFiNE](https://affine.pro)
workspace: your list's open tasks appear as todo blocks under a `## Tasks`
heading in that list's document, you tick them in AFFiNE, and the next sync
closes them in Checkvist. Days are written too — a `## Log` block in that day's
document, from the same renderer the Obsidian daily-note writer uses.

`- [ ]` is a real AFFiNE block, not text: it imports as a todo with a `checked`
flag and exports back as `- [x]`. That is the whole basis for this being
two-way.

## Why it goes through `affine-mcp`

An AFFiNE document is not text. It is a tree of CRDT blocks in a Yjs document,
synced over a websocket and stored as binary updates; markdown only exists at
the edges, through an importer and an exporter. Writing one from Swift would
mean reimplementing Yjs and the BlockSuite block schema, and then keeping both
correct against a moving target.

So the plugin does not talk to AFFiNE. It talks to
[`affine-mcp-server`](https://github.com/DAWNCR0W/affine-mcp-server), a node MCP
server that already does the Yjs work, and calls its tools over stdio — the same
protocol Takt *serves* on the other side of the app. Takt is an MCP
server for its own data (`docs/mcp-server.md`) and, here, an MCP client for
someone else's.

Two consequences worth knowing:

- **The helper is not bundled and is not ours.** It is installed by the user,
  and the plugin does nothing until it is found.
- **Takt never sees an AFFiNE password.** Credentials live in
  `~/.config/affine-mcp/config`, written by `affine-mcp login`. The plugin
  inherits that session by launching the helper; it has no way to read it and no
  reason to.

## Setup

```bash
npm install -g affine-mcp-server
affine-mcp login          # AFFiNE Cloud, or --base-url for self-hosted
```

Then in **Settings → AFFiNE**:

1. Switch on **Enable AFFiNE integration**.
2. Check the **Server** line names a resolved `affine-mcp`. If the search missed
   it — an unusual npm prefix, a version manager the locator does not know —
   paste the path in. `PRIORITY_AFFINE_MCP_PATH` overrides it for a single run.
3. Click **Load Workspaces**. This doubles as the connection test: it is the
   cheapest call that proves the helper starts, signs in and answers. Pick the
   workspace to write into, or leave it unset to use whatever `affine-mcp` is
   configured for.
4. Optionally set a **parent document** id. New documents (checklists, days) are linked under
   it, so they appear in the sidebar instead of only in search.

Under nvm the helper is a `#!/usr/bin/env node` script in a directory a menu bar
app's PATH has never heard of, so the plugin prepends the helper's own directory
to `PATH` when launching it — an npm-installed binary sits beside the node that
installed it.

## Commands

| Command | What it does |
| --- | --- |
| `sync affine` (`affine`, `send to affine`) | Reads back what you ticked, closes it, writes the open list |
| `open affine` | Opens this list's checklist in the browser |
| `affine daily` (`affine log`) | Writes today's completions and dailies into today's document |

None of the three needs a task selected: they are about a list and a day.

## The sync, in order

1. Find the list's document — remembered by list id, else by title (the list's
   own name; `Priority Tasks` when there isn't one).
2. Export its markdown and read the `## Tasks` section.
3. Every ticked box resolves to a task id and is **closed in Checkvist** —
   including its recurrence, so a repeating task ticked in AFFiNE schedules its
   next occurrence exactly as it would here.
4. Re-read the list and write the still-open tasks back.

The order matters. Writing the checklist before the closes land would put every
box that was just ticked straight back.

Each item is written as `- [ ] [Task text](checkvist-permalink)`. The link is
what makes a tick traceable: reword the item in AFFiNE and it still resolves to
its task. An offline task has no permalink, so it is written as plain text and a
tick against it does nothing.

## What is left alone

Takt owns the `## Tasks` heading and the blocks under it, up to the next
heading of the same level or shallower. Everything else in that document is
yours. A line typed into the section by hand — `- [ ] buy milk`, or a note
between the items — is read out and put back rather than deleted; it just does
not become a task.

Two safeguards are worth knowing:

- **A document that markdown cannot carry is never rewritten.** The exporter
  renders a block it has no markdown for as a comment, so replacing a document
  with its own exported markdown would delete that block. If the export comes
  back lossy, the sync refuses and says which document.
- **An unchanged list is not rewritten at all.** The comparison is item by item,
  not text by text, because AFFiNE's exporter backslash-escapes every ASCII
  punctuation character in a link label: `Ship (v1.2)` returns as
  `Ship \(v1\.2\)`. Comparing the text would report a change on every sync,
  forever.

## Where the pieces live

| Piece | File |
| --- | --- |
| JSON-RPC framing, request builders, result parsing | `Sources/TaktCore/MCPWire.swift` |
| Finding the helper, and the PATH to launch it with | `Sources/TaktCore/AFFiNEHelperLocator.swift` |
| Document rendering and heading-delimited merging | `Sources/TaktCore/AFFiNEDocumentMarkdown.swift` |
| The checklist: rendering it, and reading ticks back | `Sources/TaktCore/AFFiNEChecklistMarkdown.swift` |
| The process, its pipes, and the watchdog | `Takt/Plugins/Native/AFFiNE/AFFiNEMCPSession.swift` |
| Tool orchestration and the task → document memory | `Takt/Plugins/Native/AFFiNE/AFFiNEExportService.swift` |
| The plugin, and its settings page | `Takt/Plugins/Native/AFFiNE/NativeAFFiNEIntegrationPlugin*.swift` |
| Ordering the close-then-write, and reporting it | `Takt/Managers/IntegrationCoordinator+AFFiNE.swift` |

Closing a task is the mutation service's job, not an integration's, so the
plugin hands the ticked ids back through a callback and the coordinator applies
them. That is why `syncChecklist` takes a `closingTicked` closure rather than a
repository.

A session is started per request and torn down after it. The alternative — a
resident node process with an AFFiNE session going stale in the background — is
a lifecycle problem in exchange for latency nobody is waiting on.
