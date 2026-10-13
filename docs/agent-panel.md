# The agent panel

The left dock's **Agent** tab (`Cmd+Shift+A` as in Zed, or `Cmd+Ctrl+A`, or the sparkles glyph at the left
of the status bar) is a conversation with an assistant about your tasks, laid
out like Zed's agent panel. The assistant is the user's own **Claude Code**,
run headless, the way Zed runs its external agents: no API key, no account of
Takt's own, just the `claude` login already on the machine.

The rule it is built around:

> The assistant may **read** freely. Its **writes** — adding, editing,
> completing, moving or deleting anything — apply straight away, and each is
> shown to the user as a card saying what changed, with an **Undo** that takes
> back exactly that change. There are no shell or file tools at all.

That replaced the rule the panel was first built on, that every write waits
for the user's click, at the user's own decision (2026-10-13). The old rule
is still there for anyone who wants it: **Settings ▸ Agent ▸ Ask before
changing tasks** (off by default; `UserDefaults` key
`agentAsksBeforeChangesV1`) makes every write wait for Approve again. The
setting is read when a thread's process starts, so it applies from the next
thread.

## Where the pieces live

| File | What it is |
|---|---|
| `Sources/TaktCore/AgentStreamProtocol.swift` | The stream-json wire format: lines in to `AgentStreamEvent`s, and the user messages and `control_response`s out |
| `Sources/TaktCore/AgentToolPolicy.swift` | Which tools are pre-allowed, the exact `claude` invocation, where `claude` is looked for, the system prompt |
| `Sources/TaktCore/AgentToolSummary.swift` | A tool call in words, for the change card and the read lines |
| `Sources/TaktCore/AgentContext.swift` | The standing instructions' block and folder chain, and the ledger that sends a block only when it changed |
| `Takt/WorkspaceAgentInstructions.swift` | The app's view of the standing instructions (kept in the workspace, `core/src/agent_instructions.rs`), and the field they are written in |
| `Takt/WorkspaceAgentSession.swift` | The process: launch, the line reader, change cards and approvals, stop, new thread |
| `Takt/WorkspaceAgentPane.swift` | The transcript, the change card with its Undo, the setup state |
| `Takt/WorkspaceAgentInputField.swift` | The message field (an `NSTextView`: Return sends, Shift+Return is a new line) |
| `Takt/WorkspaceLeftDock.swift` | The dock's tab bar: Lists and Agent |

The first three are pure and tested in `corelogic-tests/AgentStreamProtocolTests.swift`
and `AgentToolPolicyTests.swift`; the stream-json fixtures there are lines
from a real session.

## Finding Claude Code

A GUI app sees neither the shell's `PATH` nor its aliases — `claude` is often an
alias — so the binary is looked for directly, first match wins
(`AgentCLILocator`):

1. A path set by hand in the panel's setup state
   (`UserDefaults` key `agentClaudeExecutablePathV1`)
2. `~/.local/bin/claude` (the native installer)
3. `~/.claude/local/claude` (the old local install)
4. `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`

If none is executable the panel says so, lists the paths it tried, and takes a
path. That setup state stays at the top of the panel, transcript or not, for as
long as there is no `claude` to run.

When Claude Code is there but fails — a turn ending in an error, or the
process dying with something on stderr — the panel shows the CLI's message and,
for the failures it knows, the fix under it (`AgentFailureAdvice`): not signed
in (run `claude` in Terminal and `/login`), too old for these flags (`claude
update`), a usage limit, or no connection. The CLI's own wording is written for
a terminal the panel does not have.

Takt's MCP server is found the way `Takt --mcp-server` finds it
(`MCPHelperLocator`): `$PRIORITY_MCP_EXECUTABLE_PATH`, then the bundled helper
at `Contents/Helpers/takt`, then an installed CLI. A build made with
`TAKT_SKIP_CLI_BUNDLE=1` and no installed CLI has no tools to give the
assistant, and the panel says that instead of starting.

## The invocation

One process per thread, started on the first message, in an empty working
directory of the app's own (`~/Library/Application Support/Takt/Agent`) so
no project's `CLAUDE.md` or `.mcp.json` is picked up:

```text
claude -p
  --input-format stream-json --output-format stream-json --verbose
  --mcp-config '{"mcpServers":{"takt":{"args":["--mcp-server"],"command":"<helper>","type":"stdio"}}}'
  --strict-mcp-config
  --tools ""
  --allowedTools mcp__takt__task_lists,mcp__takt__task_fetch,…   (reads and writes; reads only when asking first)
  --permission-mode manual
  --permission-prompt-tool stdio
  --setting-sources ""
  --no-session-persistence
  --system-prompt "<AgentSystemPrompt.text>"
```

Each flag is there for the rule:

- **`--tools ""`** removes every built-in tool — Bash, Read, Edit, Write,
  WebFetch, WebSearch, Task and the rest. Verified on Claude Code 2.1.283: the
  session's `init` line lists the 33 `mcp__takt__*` tools and nothing else.
- **`--strict-mcp-config`** loads only the server named in `--mcp-config`, so
  the user's other MCP servers are not there.
- **`--setting-sources ""`** skips the user's, project's and local settings
  files. A permission rule, hook or plugin written for coding sessions cannot
  allow anything here, or run. (The user's `CLAUDE.md` is not loaded either.)
- **`--permission-mode manual`** is the mode that asks for whatever is not
  pre-allowed. `auto` would let a classifier answer and
  `acceptEdits`/`bypassPermissions` would not ask at all.
- **`--allowedTools`** pre-allows Takt's classified tools: the reads and the
  writes, or only the reads with "Ask before changing tasks" on
  (`AgentToolPolicy.preAllowedTools`). A tool in neither list — one added to
  the CLI and not yet classified — falls through to the permission prompt
  either way.
- **`--permission-prompt-tool stdio`** sends that prompt to the app, on the
  same stdout stream, as a control request (below).
- **`--no-session-persistence`**: a thread lives as long as its process, and
  nothing is written to `~/.claude/projects`.
- **`--system-prompt`** replaces Claude Code's own, which is about writing
  software with tools this process does not have. It says where the assistant
  is, today's date, what the tools are, and that every change needs approval —
  so it should say what it is about to change, make one change per call, and
  not retry a declined one.

The environment is the app's, with a usable `PATH` and without the variables
that mark a nested Claude Code session. The MCP helper inherits it, so it
reads the same database and CLI credentials as any other MCP client of
Takt's.

Each message is prefixed with one line saying what is on screen — the list and
the selected task, by name and id — so "this task" means something. It is sent
to the assistant and not shown in the transcript.

The tasks on screen go with it too, top to bottom with their ids, capped at 30
(`AgentSystemPrompt.visibleTasks`), so "these", "the top three" and
"everything here" need no read first. Like the standing instructions below, the
list is sent only when it differs from the last one this process was sent.

## Standing instructions

The user can write instructions for the assistant at three scopes: the whole
account (Settings ▸ Agent), a folder, and a list (each in its settings sheet,
`oo` on the list or the sidebar's context menu). The assistant can keep them
too, through `agent_instructions_get` and `agent_instructions_set`.

They live in the workspace database, in `agent_instructions`
(`v25_agent_instructions`), one row per scope keyed `account`,
`folder:<id>` or `list:<id>`. The reads and writes are the Rust core's
(`core/src/agent_instructions.rs`), called by the app's store
(`WorkspaceStore.agentInstructionTexts` and `setAgentInstructions`) and by the
CLI's two tools alike. Each edit is an "Edit Agent Instructions" undo step —
"MCP: Edit Agent Instructions" when the assistant made it — and blank text
clears a scope. The table syncs (see `docs/sync.md`): the tools are the CLI's,
which runs wherever the workspace does, and the scope-shaped key means two
devices writing the account's instructions write one row.

Before v25 they were kept in this Mac's preferences
(`agentInstructionsAccountV1`, and `agentInstructionsByFolderV1` /
`agentInstructionsByListV1` keyed by id). On first launch the app copies them
in once (`WorkspaceStore.migrateAgentInstructionPreferences`, flagged by
`agentInstructionsInWorkspaceV1`), outside the journal and without
overwriting a scope the workspace already has text for; the preferences are
left where they were.

`WorkspaceAgentInstructions` is the app's view of the rows. The account field
saves 0.7 s after the last keystroke (and before a message is sent), so a
sentence is one undo step; the folder and list fields save with their sheet.
It reads the rows again on every workspace reload, so an edit the assistant,
the CLI or another device made arrives through the same `PRAGMA data_version`
poll as any other external write.

The system prompt tells the assistant to keep them: when the user states a
durable preference, fact or convention about a list, a folder or how they
work, save it to the narrowest scope that fits, as a change the user sees
and can undo (or approve first, with asking on); read the scope first
and merge rather than pile up duplicates; never save a one-off request. The
change card for `agent_instructions_set` shows the scope's whole text
before, struck through, over its whole text after — an append shows the text
it would make, and clearing shows "None" — with Undo like any other change.

A message starts with the instructions that apply where the user is
(`WorkspaceViewModel.agentInstructionScopes`), as one block: the account's,
then each folder enclosing the current list from the outermost in, then the
list's own, each labelled (`Folder "Work":`), so the narrowest is read last. In
a folder scope it is the account and that folder's chain; in Everything or a
filter list, the account alone.

The system prompt is fixed when the process starts, and the list changes during
a thread, so the block goes with the message rather than the prompt — and only
when it differs from the last one this process was sent
(`AgentContextLedger`). Moving to a list with none sends one line saying the
earlier ones no longer apply. An instruction the assistant has just saved
changes the block, so the next message carries it again with the new text. Stop or New thread starts a fresh process and a
fresh ledger, so its first message carries them again.

The line above the message field names the scopes that apply — written ones in
the muted ink, unwritten ones dim — and each opens where it is written.

## Tool policy

Classified in `core/src/agent_tools.rs`, which the CLI's tests hold to its
whole tool table (47 tools):

**Read-only, pre-allowed** — shown as one muted line each (`task_search · milk`):

`task_lists`, `task_fetch`, `task_search`, `task_metadata`, `daily_log_fetch`,
`dailies_list`, `focus_status`, `focus_history`, `workspace_tree`,
`workspace_tasks`, `workspace_task_dependencies`, `workspace_filter_lists`,
`workspace_filter_list_tasks`, `workspace_board_columns`, `agent_instructions_get`

**Writes** — the other 32. Pre-allowed, each shown as a change card with an
Undo; with "Ask before changing tasks" on, each waits for Approve:

`task_add`, `task_update`, `task_note_add`, `task_move`, `task_reparent`,
`project_move`, `task_complete`, `task_reopen`, `task_invalidate`,
`task_delete`, `list_create`, `task_matrix_set`, `daily_add`, `daily_update`,
`daily_tick`, `workspace_task_add`, `workspace_task_update`,
`workspace_task_move`, `workspace_task_to_list`, `workspace_task_delete`,
`workspace_task_blocker_add`, `workspace_task_blocker_remove`,
`workspace_filter_list_create`, `workspace_filter_list_update`,
`workspace_filter_list_delete`, `workspace_folder_create`, `workspace_list_create`, `workspace_list_move`,
`workspace_list_delete`, `workspace_board_column_set`, `workspace_board_column_delete`,
`agent_instructions_set`

The CLI's `every_declared_tool_is_classified_as_a_read_or_a_write` test holds
the two lists to the table exactly, so a tool added to the CLI fails `cargo
test` until it is classified there. A tool missing from both lists is not
pre-allowed at all, so it asks even when changes do not.
A permission request for anything that is not a Takt tool is refused
outright rather than put to the user.

## Change cards and Undo

A write the command line pre-allowed runs as soon as the assistant calls it.
The panel draws its card from the `tool_use` in the assistant's message,
which arrives before the tool runs: the action in words ("Add a task"), each
argument labelled, with ids resolved to list and task names, and the raw input
behind a disclosure. A change to a workspace task (`workspace_task_update`,
`workspace_task_move`) shows what each field held struck through above what
it holds now — the title, notes, status, list or parent — read from the
workspace as the app last loaded it, which the CLI's write reaches only on the
next poll. An `agent_instructions_set` shows the scope's whole text before and
after. The card then follows the tool's result: running, done, or failed with
the tool's message.

Every workspace write the CLI makes is one undo step in the journal, and its
result names it: the payload carries `undo_step`, the step's journal group
(`cli/src/tools.rs`, `AgentToolResult.undoStep`). With it, a done card has an
**Undo** that takes back exactly that step:

- The core replays the step backwards inside a savepoint and checks that every
  row a later standing step touched is still as that step left it
  (`core/src/journal/steps.rs`, `CoreWorkspace::step_undo_plan`). If so, the
  step goes back alone and the later ones stay — the menu's Undo is unchanged
  and still takes back the newest step.
- If a later step built on it — an edit to the task it added — the step can
  only go back together with the later steps that touched its rows, newest
  first, and the button says so before it is pressed: **Undo with 1 later
  change** (the help names them). When even that would leave something
  inconsistent — a subtask added under the task it created would go with it by
  cascade — the button offers to take back every later step, which is what
  pressing Edit ▸ Undo that many times would do.
- Once undone the card says **Undone**, with **Redo** when putting it back
  would not disturb a later step. A newer change drops the redo, as it drops
  the menu's; a step trimmed off the journal's hundred, or dropped that way,
  leaves the card saying it is no longer in the undo history.
- The plan is asked again whenever the journal moves
  (`WorkspaceViewModel.historyVersion`), so a step undone from Edit ▸ Undo
  shows as Undone on its card too.
- The next message tells the assistant which of its changes were undone
  (`AgentSystemPrompt.undone`), and the system prompt tells it not to make an
  undone change again.

Keys, in keeping with the panel's own: **Tab** from the message field moves to
the newest card that can be undone (or the pending card, when there is one),
**Return** there presses its button — Undo, or Redo once undone — and **Esc**
goes back to the field. The writes the journal does not cover (the Checkvist
`task_*` tools and the dailies) say done and have no Undo.

## Asking first

With "Ask before changing tasks" on, the writes are not pre-allowed. When the
assistant calls one, Claude Code does not run it. It writes a control request
to stdout and waits:

```json
{"type":"control_request","request_id":"8f11…","request":{"subtype":"can_use_tool",
 "tool_name":"mcp__takt__workspace_task_add","input":{"title":"Milk","list_id":"94EA…"},
 "tool_use_id":"toolu_01…", …}}
```

The panel shows it as the same card, saying what the change would do, with the
before values read when the request arrives. A delete's Approve is in the
danger hue. The card waits for one of two answers, written to the CLI's stdin:

```json
{"type":"control_response","response":{"subtype":"success","request_id":"8f11…",
 "response":{"behavior":"allow","updatedInput":{"title":"Milk","list_id":"94EA…"}}}}

{"type":"control_response","response":{"subtype":"success","request_id":"8f11…",
 "response":{"behavior":"deny","message":"The user declined this change. …"}}}
```

- **Approve** is the button, or Return while the card itself holds the
  keyboard (Tab from the message field moves to it). `updatedInput` is exactly
  the input the card showed. There is no timer and no default answer.
- **Deny** is the button or Esc on the card. The tool never runs and the
  assistant is told not to retry.
- **No answer** means nothing happens. Hiding the panel does not answer; the
  card is still there when it comes back. While a card is pending the field
  will not send, so a Return meant for a message cannot land anywhere else.
- **Stop** (the tab bar's stop glyph), **New thread**, or the process exiting
  kills the CLI and marks every unanswered card "not answered · nothing
  changed". The tool call it was about died with the process.
- The window's key monitor treats the whole panel as a text field while it
  holds the keyboard (`WorkspaceViewModel.agentHoldsKeyboard`), so letters
  typed in the field and Return on a card reach the panel rather than the task
  list behind it.

Once approved, the card follows the tool's result like any other, Undo
included. A permission request for anything that is not a Takt tool is refused
outright rather than put to the user, in either mode.

Verified on this machine (Claude Code 2.1.283) against a throwaway database
(`PRIORITY_MCP_DB_PATH` and friends pointed at `/tmp`, no Checkvist
credentials), with the Swift code above compiled into a small driver: asked
to add a task and delete another, the CLI sent one `can_use_tool` request for
each, both were denied, the assistant reported that nothing changed, and the
database's `change_log` was untouched. The same run with the answer switched
to allow added the task.

## After a turn

The CLI writes to the workspace database directly, under the app's undo
journal, so each change is an "MCP: …" step in the Undo menu as well as on
its card. The app
picks the rows up through its `PRAGMA data_version` poll
(`WorkspaceViewModel+ExternalWrites.swift`), and the panel nudges that poll at
the end of each turn so a change is on screen when the assistant says it is
done.

## Multi-turn

The process stays alive with `--input-format stream-json`; a follow-up is one
more user line on stdin, and the conversation carries on. Stop ends the
process but keeps the transcript to read; the next message starts a fresh
process with no memory of it. New thread clears both.
