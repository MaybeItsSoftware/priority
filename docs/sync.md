# Sync

Priority's workspace is a local SQLite database on every device. The Mac, the
iPhone and the Android phone each keep a full copy and work offline. Sync
copies row changes between them through one small server (`sync-server/`,
hosted on Railway). The server stores rows and merges them; it knows nothing
about tasks.

Three clients implement the client half: Swift (`Sources/PriorityWorkspace/
WorkspaceStore+Sync.swift` with `Sources/PrioritySync`, used by macOS and iOS),
Kotlin (`mobile/android/data`), and, passively, the Rust CLI. The CLI never
talks to the server, but its writes go through the same triggers, so they sync
the next time the app does.

## What is synced

Every row of these tables, keyed by the column shown:

| Table | Key |
| --- | --- |
| `workspaces` | `id` |
| `list_folders` | `id` |
| `task_lists` | `id` |
| `tasks` | `id` |
| `task_metadata` | `taskId` |
| `task_conditions` | `id` |
| `kanban_boards` | `id` |
| `dailies` | `id` |
| `daily_contributions` | `id` |
| `focus_sessions` | `id` |
| `focus_queue_items` | `id` |
| `focus_work_blocks` | `id` |
| `focus_awards` | `id` |
| `themes` | `id` |
| `preferences` | `key` |

`themes` and `preferences` arrive in `v18_themes_and_preferences`:
`themes(id TEXT PRIMARY KEY, json TEXT NOT NULL, updatedAt DATETIME NOT NULL)`
and `preferences(key TEXT PRIMARY KEY, value TEXT, updatedAt DATETIME NOT NULL)`.
They hold the user's theme files and the cross-device choices described in
[themes](themes.md#the-chosen-theme-follows-you). Neither is journalled for undo.

The following are not synced: the undo journal (`undo_control`, `change_log`), the FTS index
(rebuilt by its own triggers as synced rows land), `grdb_migrations`, and the
sync tables themselves. Day-log files stay per device. Theme *files* do
too, but their text travels as `themes` rows (the Mac mirrors its themes
folder into the table, see [themes](themes.md#the-chosen-theme-follows-you)).

## Local schema (`v17_sync`)

```sql
CREATE TABLE sync_control (id INTEGER PRIMARY KEY,
  recording INTEGER NOT NULL DEFAULT 0,   -- 1 once the device is signed in
  applying  INTEGER NOT NULL DEFAULT 0);  -- 1 while remote rows are written
INSERT INTO sync_control (id) VALUES (0);

CREATE TABLE sync_outbox (seq INTEGER PRIMARY KEY AUTOINCREMENT,
  tableName TEXT NOT NULL, rowId TEXT NOT NULL,
  operation TEXT NOT NULL,          -- 'insert' | 'update' | 'delete'
  changedJSON TEXT,                 -- update only: JSON array of column names (may hold nulls; ignore them)
  changedAtMs INTEGER NOT NULL);    -- wall clock when the trigger fired

CREATE TABLE sync_state (id INTEGER PRIMARY KEY,
  deviceId TEXT NOT NULL, cursor INTEGER NOT NULL DEFAULT 0,
  hlc TEXT, serverURL TEXT, canonicalWorkspaceId TEXT,
  needsSnapshot INTEGER NOT NULL DEFAULT 1, lastSyncedAt DATETIME);
```

Each synced table has `sync_outbox_<table>_{insert,update,delete}` AFTER
triggers, guarded by
`WHEN (SELECT recording FROM sync_control WHERE id = 0) = 1 AND (SELECT applying FROM sync_control WHERE id = 0) = 0`.
They use plain SQL only. They must never call an application-registered
function, because the CLI and `sqlite3` write to the same file without one. Like the
undo triggers, they name their columns, so **any later migration that adds or
removes a column on a synced table must reinstall them**.

An undo is ordinary inserts and updates, so it syncs like any other edit.

## Hybrid logical clock

An HLC is the string `"<ms:013d>-<counter:04d>-<deviceId>"`. Because every part is
fixed width, plain string comparison orders HLCs correctly. A device keeps its
last HLC in `sync_state.hlc`. To stamp a change made at wall time `w`:
`ms = max(last.ms, w)`. The counter is `last.counter + 1` if `ms` equals `last.ms`,
and `0` otherwise. When it receives a row, the device advances its clock past
the row's HLC in the same way.

## Wire protocol (JSON over HTTPS)

Accounts are **Supabase Auth** users. The apps sign in with Supabase itself
(email and password, Google, or Apple), and Supabase handles confirming
emails and resetting passwords. Every request but `/health` then sends:

- `Authorization: Bearer <Supabase access token>`. The server checks its
  signature against the project's published keys and takes the account from
  its `sub`. An expired token gets `401`; the app refreshes it with Supabase
  and retries, and only a failed refresh means "signed out — sign in again".
- `X-Priority-Device: <uuid>`, the device's own id, made once and kept.
  Required on `/v1/push` (every write records its device); used elsewhere to
  mark the current device.

A value is a JSON `null`, number or string, exactly as SQLite stores it. Dates
are GRDB's `"yyyy-MM-dd HH:mm:ss.SSS"` text in UTC, and booleans are `0`/`1`.

### Devices and the account

- `POST /v1/devices` `{ "id", "name", "platform" }` records the device on the
  account. Sent after every sign-in; a device that was on another account
  moves to this one.
- `GET /v1/account` returns `{ "accountId", "email", "devices": [{ "id",
  "name", "platform", "createdAt", "lastSeenAt", "current" }] }`.
- `POST /v1/sign-out` takes the calling device off the list. The app signs out
  of Supabase itself and keeps its workspace.
- `POST /v1/account/delete` deletes the account's rows, its devices and the
  Supabase user. The app asks the user to confirm first. Every device keeps
  its local copy.

### Signing in on the Mac and iPhone

`Sources/PrioritySync` holds both apps' half. `SyncServer` names the
Supabase project (its URL and publishable key) and the redirect,
`takt://auth-callback`, which has to be on the project's allowed
redirect URLs.

- **Email and password**: sign in, or create an account. When the project
  asks for confirmed emails, signing up says "check your email". "Forgot
  password?" calls Supabase's `recover`. The emailed link opens the app, which
  signs in and asks for a new password.
- **Google**: Supabase's web flow in `ASWebAuthenticationSession`, coming back
  on `takt://auth-callback`.
- **Apple**: on the iPhone, the native sheet. The ID token and a hashed nonce
  go to Supabase's `id_token` grant. The Mac is signed without a provisioning
  profile, so it can't hold the Sign in with Apple entitlement and uses the
  web flow, as for Google.

The Supabase session lives in the Keychain, through the SDK's own
`KeychainLocalStorage`, readable after first unlock so a background refresh
can sync. Before each request the transport asks the client for a token,
which refreshes it first if it has expired. A `401` refreshes once and
retries. A refresh Supabase refuses is "signed out". A refresh that fails
because the device is offline is only a failed cycle.

The device id is a UUID, made the first time and kept in the Keychain across
sign-outs. A device signed in under the old server-issued accounts keeps its
id, drops the old token, and asks to sign in again.

### `POST /v1/push`
Request:
```json
{ "changes": [
  { "table": "tasks", "id": "<uuid>", "op": "upsert", "hlc": "<hlc>",
    "values": { "title": "Buy milk", "updatedAt": "2026-10-02 09:00:00.000" } },
  { "table": "tasks", "id": "<uuid>", "op": "delete", "hlc": "<hlc>" } ] }
```
Response: `{ "accepted": <n>, "cursor": <server seq after applying> }`

For each change, the server resolves it against the stored row
`(data, colHlc, deleted, deletedHlc)`:
- **upsert:** for each column, the incoming value wins if its HLC is greater than
  `colHlc[col]`, or if the column has none. If the row is deleted and
  `hlc > deletedHlc`, the row comes back: `deleted = false`, and the incoming
  columns are applied over the old data. That is what undoing a delete looks
  like. If `hlc <= deletedHlc`, the change is ignored.
- **delete:** the row is deleted if `hlc` is greater than every `colHlc`. Then
  `deleted = true` and `deletedHlc = hlc`.
- If anything changed, the row gets a new `seq` from one global sequence.
  `lastDeviceId` records the pusher, for diagnostics only.

Pushing the same change twice changes nothing.

### `GET /v1/changes?since=<seq>&limit=<n>&wait=<seconds>`
Response:
```json
{ "rows": [ { "table": "tasks", "id": "<uuid>", "deleted": false,
              "values": { "...every column..." }, "hlc": "<max colHlc>" } ],
  "cursor": 1234, "hasMore": false }
```
The response holds the rows whose `seq > since`, in `seq` order, **including
rows the caller itself last wrote**. Skipping those looks like a free
saving, but it's wrong: a row the caller last wrote can still hold another
device's earlier edit to a different column that the caller has never seen.
Re-applying your own row is harmless. It also returns the cursor to resume
from. If there is nothing to send and `wait > 0` (at most 25), the request
waits for new rows, woken through Postgres `LISTEN/NOTIFY`.

### `GET /health`
Returns `200 {"ok":true}`.

## A client sync cycle

1. **First cycle only:** if `needsSnapshot = 1`:
   - Set `recording = 1` and add an `insert` outbox entry for every existing
     row in the synced tables, in parent-first table order.
   - Clear `needsSnapshot`.
   - Pull before pushing (step 3, then step 2).
2. **Push:**
   - Read the outbox in `seq` order and merge entries for the same row. The
     merged op is `delete` if the last entry is a delete; otherwise `upsert`,
     with every column if any entry was an insert, or else the union of the
     changed columns.
   - Read the values from the **live row** at push time.
   - Stamp each change with an HLC from its newest `changedAtMs`.
   - Send them in batches of 500. After each accepted batch, delete the outbox
     entries up to the batch's highest `seq`.
3. **Pull:**
   - Fetch pages until `hasMore` is false.
   - Apply **all of them in one transaction** with `applying = 1` and
     `PRAGMA defer_foreign_keys = ON`:
     - Upsert: `UPDATE` if the row exists, else `INSERT`. Never use `INSERT OR REPLACE`, because a replace deletes, and a delete cascades.
     - Delete: `DELETE`.
     - Skip any row that still has an outbox entry, so a local edit made
       during the cycle is not overwritten. The next cycle resolves it.
     - If an insert hits a unique conflict on another key
       (`daily_contributions(dailyId, dayKey)`,
       `tasks(sourceSystem, sourceId)`, `task_lists(workspaceId, systemRole)`),
       the **smaller id wins on every device**, so two devices that made a row
       for the same key settle on the same one instead of each deleting its own.
       If the local row is smaller, keep it and queue a `delete` outbox entry for
       the incoming id. Otherwise delete the local row (recording on) and insert
       the incoming one. For `daily_contributions` the winner then takes
       `MAX(secondsLogged)` and the earlier non-null `completedAt` of the two,
       with recording on. Inbox rivals (`task_lists`) are the one exception:
       the incoming Inbox always wins and inherits the local Inbox's tasks.
   - Then set `applying = 0` and run **workspace adoption**.
   - Then delete orphans until `PRAGMA foreign_key_check` is clean. A task whose
     list was deleted on another device is removed, and its tombstone syncs.
   - Commit, then advance `cursor` and the HLC.
4. **Workspace adoption:**
   - `canonicalWorkspaceId` is the first workspace id a device ever receives
     from the server. If the server has none, it is the device's own workspace.
   - For any other local workspace:
     - Move the tasks in its Inbox into the canonical Inbox, then delete its Inbox.
     - Re-point its folders, lists and conditions to the canonical workspace.
     - Delete it.
   - These writes run with recording on, so they sync.

When it runs: when the app comes to the foreground, 2 s after the last local write,
in a long-poll loop while the app is in front, and in background refresh.

## Server storage (Postgres)

In the `sync` schema of the Supabase project's database, which the Data API
doesn't expose; RLS is on with no policies besides. `account_id` is the
Supabase user's id.

```sql
CREATE TABLE devices (id UUID PRIMARY KEY, account_id UUID NOT NULL, name TEXT,
  platform TEXT, created_at TIMESTAMPTZ, last_seen_at TIMESTAMPTZ);
CREATE SEQUENCE row_seq;
CREATE TABLE rows (account_id UUID NOT NULL, table_name TEXT, row_id TEXT,
  data JSONB NOT NULL DEFAULT '{}', col_hlc JSONB NOT NULL DEFAULT '{}',
  deleted BOOLEAN NOT NULL DEFAULT false, deleted_hlc TEXT, seq BIGINT NOT NULL,
  last_device_id UUID, PRIMARY KEY (account_id, table_name, row_id));
CREATE INDEX rows_account_seq ON rows(account_id, seq);
```

`seq` is one sequence across all accounts, so an account's cursor has gaps;
it only has to rise. Pushes are serialised per account by an advisory lock,
which keeps each account's `seq` order its commit order.
