# The agent panel

The left dock's **Agent** tab (`Cmd+Shift+A` as in Zed, or `Cmd+Ctrl+A`, or the sparkles glyph at the left
of the status bar) is a conversation with an assistant about your tasks, laid
out like Zed's agent panel. The assistant is the user's own **Claude Code**,
run headless, the way Zed runs its external agents: no API key, no account of
Priority's own, just the `claude` login already on the machine.

The rule it is built around is the one chosen when it was added:

> The assistant may **read** freely. Every **write** — adding, editing,
> completing, moving or deleting anything — is shown to the user and runs only
> after they approve it with a click. Nothing runs unattended, and there are no
> shell or file tools at all.

## Where the pieces live

| File | What it is |
|---|---|
| `Sources/PriorityCore/AgentStreamProtocol.swift` | The stream-json wire format: lines in to `AgentStreamEvent`s, and the user messages and `control_response`s out |
| `Sources/PriorityCore/AgentToolPolicy.swift` | Which tools are read-only, the exact `claude` invocation, where `claude` is looked for, the system prompt |
| `Sources/PriorityCore/AgentToolSummary.swift` | A tool call in words, for the approval card and the read lines |
| `Priority/WorkspaceAgentSession.swift` | The process: launch, the line reader, approvals, stop, new thread |
| `Priority/WorkspaceAgentPane.swift` | The transcript, the approval card, the setup state |
| `Priority/WorkspaceAgentInputField.swift` | The message field (an `NSTextView`: Return sends, Shift+Return is a new line) |
| `Priority/WorkspaceLeftDock.swift` | The dock's tab bar: Lists and Agent |

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
path.

Priority's MCP server is found the way `Priority --mcp-server` finds it
(`MCPHelperLocator`): `$PRIORITY_MCP_EXECUTABLE_PATH`, then the bundled helper
at `Contents/Helpers/priority`, then an installed CLI. A build made with
`PRIORITY_SKIP_CLI_BUNDLE=1` and no installed CLI has no tools to give the
assistant, and the panel says that instead of starting.

## The invocation

One process per thread, started on the first message, in an empty working
directory of the app's own (`~/Library/Application Support/Priority/Agent`) so
no project's `CLAUDE.md` or `.mcp.json` is picked up:

```text
claude -p
  --input-format stream-json --output-format stream-json --verbose
  --mcp-config '{"mcpServers":{"priority":{"args":["--mcp-server"],"command":"<helper>","type":"stdio"}}}'
  --strict-mcp-config
  --tools ""
  --allowedTools mcp__priority__task_lists,mcp__priority__task_fetch,…   (the read-only set below)
  --permission-mode manual
  --permission-prompt-tool stdio
  --setting-sources ""
  --no-session-persistence
  --system-prompt "<AgentSystemPrompt.text>"
```

Each flag is there for the rule:

- **`--tools ""`** removes every built-in tool — Bash, Read, Edit, Write,
  WebFetch, WebSearch, Task and the rest. Verified on Claude Code 2.1.283: the
  session's `init` line lists the 33 `mcp__priority__*` tools and nothing else.
- **`--strict-mcp-config`** loads only the server named in `--mcp-config`, so
  the user's other MCP servers are not there.
- **`--setting-sources ""`** skips the user's, project's and local settings
  files. A permission rule, hook or plugin written for coding sessions cannot
  pre-approve a write here. (The user's `CLAUDE.md` is not loaded either.)
- **`--permission-mode manual`** is the mode that asks. `auto` would let a
  classifier answer and `acceptEdits`/`bypassPermissions` would not ask at all.
- **`--allowedTools`** pre-allows exactly the read-only tools. Everything else
  falls through to the permission prompt.
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
Priority's.

Each message is prefixed with one line saying what is on screen — the list and
the selected task, by name and id — so "this task" means something. It is sent
to the assistant and not shown in the transcript.

## Tool policy

From `cli/src/tools.rs`, which is the whole tool table (33 tools):

**Read-only, pre-allowed** — shown as one muted line each (`task_search · milk`):

`task_lists`, `task_fetch`, `task_search`, `task_metadata`, `daily_log_fetch`,
`dailies_list`, `focus_status`, `focus_history`, `workspace_tree`,
`workspace_tasks`

**Writes, asked every time** — the other 23:

`task_add`, `task_update`, `task_note_add`, `task_move`, `task_reparent`,
`project_move`, `task_complete`, `task_reopen`, `task_invalidate`,
`task_delete`, `list_create`, `task_matrix_set`, `daily_add`, `daily_update`,
`daily_tick`, `workspace_task_add`, `workspace_task_update`,
`workspace_task_move`, `workspace_task_to_list`, `workspace_task_delete`,
`workspace_folder_create`, `workspace_list_create`, `workspace_list_move`

`AgentToolPolicyTests` holds the two lists to the table: disjoint, and 33
between them. A tool added to the CLI is therefore a write until someone
classifies it — the safe default — and the count in that test is the reminder.
A permission request for anything that is not a Priority tool is refused
outright rather than put to the user.

## The approval flow

When the assistant calls a write tool, Claude Code does not run it. It writes
a control request to stdout and waits:

```json
{"type":"control_request","request_id":"8f11…","request":{"subtype":"can_use_tool",
 "tool_name":"mcp__priority__workspace_task_add","input":{"title":"Milk","list_id":"94EA…"},
 "tool_use_id":"toolu_01…", …}}
```

The panel shows it as a card: the action in words ("Add a task"), each
argument labelled, with ids resolved to list and task names, and the raw input
behind a disclosure. A delete's Approve is in the danger hue. The card waits
for one of two answers, written to the CLI's stdin:

```json
{"type":"control_response","response":{"subtype":"success","request_id":"8f11…",
 "response":{"behavior":"allow","updatedInput":{"title":"Milk","list_id":"94EA…"}}}}

{"type":"control_response","response":{"subtype":"success","request_id":"8f11…",
 "response":{"behavior":"deny","message":"The user declined this change. …"}}}
```

- **Approve** is the button, or Return while the card itself holds the
  keyboard (Tab from the message field moves to it). `updatedInput` is exactly
  the input the card showed. There is no timer, no default answer and no
  "always allow"; each write is its own question.
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

Once approved, the card follows the tool's result: running, done, or failed
with the tool's message.

Verified on this machine (Claude Code 2.1.283) against a throwaway database
(`PRIORITY_MCP_DB_PATH` and friends pointed at `/tmp`, no Checkvist
credentials), with the Swift code above compiled into a small driver: asked
to add a task and delete another, the CLI sent one `can_use_tool` request for
each, both were denied, the assistant reported that nothing changed, and the
database's `change_log` was untouched. The same run with the answer switched
to allow added the task.

## After a turn

The CLI writes to the workspace database directly, under the app's undo
journal, so each approved change is an "MCP: …" step in the Undo menu. The app
picks the rows up through its `PRAGMA data_version` poll
(`WorkspaceViewModel+ExternalWrites.swift`), and the panel nudges that poll at
the end of each turn so a change is on screen when the assistant says it is
done.

## Multi-turn

The process stays alive with `--input-format stream-json`; a follow-up is one
more user line on stdin, and the conversation carries on. Stop ends the
process but keeps the transcript to read; the next message starts a fresh
process with no memory of it. New thread clears both.
