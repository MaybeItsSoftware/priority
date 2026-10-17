# End-to-end encrypted sync on Supabase alone

A plan, written 2026-10-17. Nothing here is built yet. When a step lands,
[sync](sync.md) becomes the description of what is, and this file records
how it got there.

Today a device's workspace reaches the others through `sync-server/`, a Rust
service on Railway that merges rows into `sync.rows` in the Supabase
project's Postgres. Every value it stores is plaintext: task titles, notes,
agent instructions, theme files. Anyone who can read that database (Railway,
Supabase, whoever holds the session-pooler password, a leaked backup) can read
the workspace.

The goal is two things, which can ship separately:

1. **The server can no longer read the workspace.** Each column value is
   sealed on the device under a key only the user's devices hold. The server
   still merges, column by column, by hybrid logical clock, because the
   clocks and the shape of each row stay readable to it; it just never sees
   a value.
2. **There is no server of our own.** The merge becomes a Postgres function
   the apps call through Supabase's Data API, Supabase Realtime replaces the
   long poll, and the Railway service is switched off.

The sibling app LibreLog (`~/Projects/Apps/dailylog`, `SPEC.md` §12.3–12.5,
`supabase/migrations/`) already syncs end-to-end encrypted on Supabase
alone. This plan reuses its crypto, its key handling and pairing, and its
Supabase scaffolding. It does not reuse its storage model, for reasons given
under [Why not LibreLog's op log](#why-not-librelogs-op-log).

## Where things are today

- **Protocol**: `docs/sync.md`. `POST /v1/push` sends changed columns with an
  HLC; `GET /v1/changes?since=&wait=` long-polls for rows past a cursor.
- **Merge**: `sync-server/rules/src/merge.rs` (crate `takt-sync-rules`), pure
  and unit-tested. Per column, the newer HLC wins; a delete is a row-level
  stamp that beats every column it is newer than. It never looks at a value.
- **Server**: `sync-server/src/push.rs` loads each row `FOR UPDATE` under a
  per-account advisory lock (`pg_advisory_xact_lock(hashtextextended('push:'
  || account, 0))`), merges, and writes it with `nextval('row_seq')`, one
  global sequence. `changes.rs` serves the feed; `notify.rs` wakes long polls
  through `LISTEN rows_changed`, which is why the server needs the session
  pooler. `devices.rs` registers devices and deletes accounts through the
  Supabase admin API with the project's secret key.
- **Storage**: `sync-server/migrations/20261003200000_initial.sql`, applied
  by sqlx at boot into the `sync` schema, which the Data API does not expose.
- **Client half**: the Rust core. `core/src/sync.rs` keeps the outbox and
  applies pulls; `core/src/sync/wire.rs` builds the push body
  (`prepare_push`) and reads pulled pages (`SyncPull::add_page`,
  `apply_pull`) with the server's own structs from
  `sync-server/rules/src/wire.rs`. The platforms only move bytes:
  `Sources/TaktSync/SyncTransport.swift` (URLSession) and
  `mobile/android/data/.../sync/SyncTransport.kt` (OkHttp).
- **Secrets on device**: the Supabase session sits in the Keychain
  (`Sources/TaktSync/SyncCredentialStore.swift`, `AfterFirstUnlock`) and, on
  Android, in a private SharedPreferences file sealed by an AndroidKeyStore
  AES-GCM key (`app/.../settings/SyncCredentialStore.kt`). Neither is in the
  workspace database, which syncs and which the CLI reads.
- **The CLI** never talks to the server. Its writes reach the outbox through
  the same triggers and are pushed by the app. Nothing in this plan changes
  that, and the CLI never needs the key.

The placement rule from [the Rust core migration](rust-core-migration.md)
holds throughout: anything every client must do the same way (sealing,
opening, hashing names, the recovery phrase, pairing, the conversion's
bookkeeping) goes in the core. The platforms keep the transport, key storage
and the screens.

---

## Step 1: seal every column value

### What the server sees

| | Today | After step 1 |
| --- | --- | --- |
| Table name | `tasks` | keyed hash, 22 characters |
| Row id | `3F2A…` | deterministic encryption of the id |
| Column names | `title`, `dueDate` | keyed hashes |
| Column values | plaintext JSON | sealed, padded, base64 |
| Per-column HLC | yes | yes, unchanged |
| Deleted flag and its HLC | yes | yes, unchanged |
| `seq`, account, device | yes | yes, unchanged |
| Device name | plaintext | sealed |
| Device platform | plaintext | plaintext |

The merge needs only the last four rows of that table, and none of
`merge.rs` changes. It compares HLCs and copies opaque values; a sealed
string is as opaque to it as a title.

### Keys

One random 256-bit **account key** per account, made on the first device
that turns encryption on. It never leaves a device except as a recovery
phrase the user writes down, or sealed to a new device during pairing.
Purpose keys are derived from it, as LibreLog derives its subkeys
(`blake3::derive_key(context, key)`):

| Context | Use |
| --- | --- |
| `takt 2026-10 sync value` | XChaCha20-Poly1305 key for column values |
| `takt 2026-10 sync name` | BLAKE3 keyed hash of table and column names |
| `takt 2026-10 sync row id` | AES-SIV key for row ids |
| `takt 2026-10 device name` | XChaCha20-Poly1305 key for device names |
| `takt 2026-10 key check` | Seals a constant so a device can tell it holds the right key |
| `takt 2026-10 device pairing` | Pairing, as LibreLog's `pairing_cipher` |

**Column values.** LibreLog's sealed format: `0x01 ‖ 24-byte nonce ‖
XChaCha20-Poly1305 ciphertext`, base64. The plaintext is the value's JSON
(`null`, a number or a string, exactly what the wire carries now), so nulls
are sealed too and the server cannot tell an empty field from a set one. The
associated data is `tableHash ‖ rowKey ‖ columnHash`, so the server cannot
move a ciphertext from one cell to another. The HLC is deliberately not in
the associated data: the feed sends only a row's newest stamp, not each
column's, and binding it would buy nothing against a server that can already
withhold an update.

Padding differs from LibreLog's, whose 256-byte floor suits one sealed batch
but not twenty cells of a row. Values pad to 32 bytes, then powers of two to
64 KiB, then 64 KiB steps. A sealed cell is then about 100 characters of
base64 for a short value. The Mac this was written on holds about 1,300 rows
in its six largest synced tables, at 8 to 17 columns each; sealed, that
account is roughly 5–6 MB on the server, against about 1.5 MB in plaintext.

**Names.** A table name becomes `base64url(blake3::keyed_hash(nameKey,
"table\0" ‖ table))[..22]` (128 bits); a column name the same over
`"column\0" ‖ table ‖ "\0" ‖ column`. They are not decrypted: a device maps
them back by hashing the tables and columns it knows. That is free, because
a client already skips a table it does not know and drops a column it does
not know (`docs/sync.md`, v22 and v28). An older client's behaviour on a
newer schema is unchanged.

**Row ids.** A row key must be deterministic, because two devices writing
the same row (a follow-up's derived id, the account's `agent_instructions`
row, a `preferences` key) must land on the same server row; and it must be
reversible, because a pulled tombstone carries no columns and the device has
to know which local row to delete. So it is AES-SIV (RFC 5297, the RustCrypto
`aes-siv` crate) over the id, with the table name as associated data,
base64url. A 36-character uuid becomes about 70 characters, inside the
server's 256-character limit. This is the one primitive LibreLog does not
use; it has no server-side merge, so it never needed a stable row key.

**Key check.** As LibreLog's `accounts.key_check`: the first device stores a
sealed constant on the account; a device given a key by pairing or a phrase
opens it before it pushes anything, so a wrong phrase fails at once rather
than by writing garbage the other devices cannot read.

### The crypto lives in the core

A new `core/src/sync/crypto.rs`, ported from LibreLog's
`core/src/crypto.rs` and `pairing.rs` (about 380 lines between them) with
Takt's contexts, plus the name hashing and AES-SIV. Same crates:
`chacha20poly1305`, `blake3`, `bip39`, `x25519-dalek`, `zeroize`,
`getrandom`, plus `aes-siv`.

Across the FFI the key is a UniFFI object, `SyncKey`, made from bytes the
platform read from its key store, or from a phrase, or from a pairing
payload, and holding them in a `Zeroizing` buffer. `prepare_push`,
`SyncPull::add_page` and `apply_pull` take an optional `SyncKey`; without
one they behave as today. Rows still never cross the FFI as records. A
platform hands the core a key and bytes, and gets bytes back.

### Where the key is kept

| Platform | Store | Notes |
| --- | --- | --- |
| Mac | Keychain, the sync service's own item, a new account name beside the session | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronisable. The Mac is signed without a provisioning profile, so iCloud Keychain is not available to it anyway. |
| iPhone | Keychain, same item and class | `ThisDeviceOnly`, so a phone restored from a backup asks to pair again rather than carrying a key out of the device. |
| Android | The `sync_credentials` file, sealed by the existing `KeystoreCredentialCipher` | When the Keystore key is wiped (the lock screen removed), the account key reads as missing and the device asks to pair again. Its workspace is untouched. |
| CLI | none | It never syncs. |

The key is never written into the workspace database. Losing it on one
device costs nothing but a pairing; losing it on every device *and* the
phrase loses only the server's copy, which every device also holds in full.
The server is a relay here, not a backup, which makes the usual E2E
"unrecoverable" warning much milder than LibreLog's.

### Recovery phrase and adding a device

On the device that makes the key: show the 24-word BIP-39 phrase once, with
the sentence LibreLog uses, adapted ("If you lose every device and this
phrase, the copy on the server can't be read. Your devices keep theirs."). A
copy button and a "Show again" in settings while the key is on the device.

A device that signs in to an encrypted account and has no key shows
**Add this device**, with three ways in:

1. **This device shows a code.** LibreLog's flow: the new device makes an
   ephemeral X25519 pair, opens a pairing row, and shows a QR code with the
   pairing id and its public key. An existing device scans it and fulfils the
   row with the account key sealed to that public key.
2. **The other device shows a code.** New for Takt, because a Mac has no
   convenient camera. The existing device makes a random 32-byte pairing
   secret, fulfils a pairing row with the key sealed under a key derived from
   that secret, and shows `takt-pair:2:<id>:<secret>` as a QR code. The new
   device scans it, takes the row and opens it. The server sees only
   ciphertext; the secret travels only on the screen. Anyone who could use
   the code would also need to be signed in to the account, within ten
   minutes, before the rightful device takes it.
3. **Type the recovery phrase.**

So a phone pairs with the Mac by scanning whichever screen shows the code,
and two Macs pair by phrase. Pairing rows live ten minutes and are deleted
when taken, as in LibreLog (`pairing_open`, `pairing_fulfil`,
`pairing_take`).

### The server's part

Small, whether it is the Railway server or, after step 2, Postgres functions:

- `accounts(account_id, epoch, key_check, encrypted_at, …)`. `epoch` is 0
  for plaintext; encryption is epoch 1. A later key rotation would be epoch
  2, by the same procedure as below.
- `rows` gains `epoch` in its primary key and in its feed index. A push and
  a pull name their epoch; the wire structs in `takt-sync-rules` gain an
  optional `epoch` that defaults to 0, so an old client's bodies still read.
- `pairings`, as LibreLog's.
- `devices.name` becomes `name_enc`.
- **Plaintext is refused once an account is encrypted.** A push to an epoch
  other than the account's current one is refused whole with `409` and
  `{"error": "This account now uses end-to-end encryption. Update Takt on
  this device to keep syncing.", "code": "account_encrypted"}`. Old clients
  already show the server's `error` as their sync failure
  (`sync_server_message`) and keep their outbox on a refusal, so the message
  reaches the user and nothing is lost. An epoch-1 push is also checked for
  shape: names must be 22 base64url characters, values must decode to a
  version-1 sealed payload of at least 41 bytes. That cannot prove a value is
  ciphertext, but it stops a client bug that sends plaintext.

### Turning it on for an existing account

The account's rows on the server are plaintext and the devices hold no
per-column clocks of their own, so the rows cannot be resealed in place.
Instead the account moves to a fresh, encrypted feed, epoch 1, filled once
from one device, and the plaintext feed is kept read-only until every device
has moved, then deleted.

**On the device that turns it on** (settings, *Turn on end-to-end
encryption*, on an up-to-date client):

1. Make the key, store it, show the phrase.
2. Run an ordinary cycle on epoch 0: push the outbox, pull to the end.
3. Ask the server to begin epoch 1 with the key check and the cursor it has
   reached. Under the account's push lock, the server refuses if any epoch-0
   row has a higher `seq` (another device pushed in between: go back to 2),
   otherwise sets `epoch = 1` and `key_check`. From here, epoch-0 pushes are
   refused.
4. Locally, in one transaction (`sync::begin_epoch` in the core): `epoch =
   1`, `cursor = 0`, `needsSnapshot = 1`, keeping the clock and
   `canonicalWorkspaceId`. The next cycle is the existing first-cycle path:
   every row goes into the outbox (`enqueue_snapshot`), a pull finds the
   empty feed, and every row is pushed sealed. The outbox is in SQLite, so an
   upload interrupted by a quit or a crash carries on at the next launch.

**On every other device**, the next push is refused with
`account_encrypted`, or the account state it reads on launch says epoch 1.
It then:

1. Pulls epoch 0 to its end. That drains the deletes and edits it had not
   yet received. Its own unpushed edits stay in the outbox and are not
   overwritten, by the existing rule that a pull skips a row with an outbox
   entry.
2. Asks for the key (pair, or phrase) and checks it against `key_check`.
   Until then it works offline as normal and its outbox grows.
3. Sets `epoch = 1`, `cursor = 0`, and `needsSnapshot = 0`. It does *not*
   upload a snapshot: a device that was behind would push stale values with
   newer clocks and win. It pulls epoch 1 and pushes its outbox, sealed. An
   edit it made before the switch is stamped at push time, as every edit is
   (`prepare_push` stamps at `max(changedAtMs, now)`), so it wins over the
   converter's snapshot of that column, exactly as a late push wins today.

If it pulls epoch 1 while the converter's upload is still under way, it
gets part of the workspace; rows it lacks it simply keeps, and the rest
arrive with later pulls. Sync never deletes a row for being absent.

**Old clients**, built before step 1, are refused on push with the message
above, and pull nothing new. They lose nothing; once updated, they take the
path above.

**The plaintext feed is deleted** when every device seen in the last 30
days has pulled epoch 1 (`devices.epoch`, recorded on each pull), or after
30 days, whichever is first. Settings also offers *Remove the unencrypted
copy now*. A device that comes back after the plaintext feed has gone
cannot drain it: it is told it was away too long, and offered *Replace this
device's copy with the account's*, which pushes its outbox first and then
pulls epoch 1 into an emptied workspace. Until the plaintext feed is gone,
the privacy goal is not met; the settings page says so plainly.

**New accounts** are encrypted from their first sign-in: a device that
finds an epoch-0 account with no rows and no other device begins epoch 1
straight away. Signing in to an empty account is the only time a key is
made without asking.

### What still leaks

E2E hides values. It does not hide:

- **Who and when.** The account's email, and every sign-in, are Supabase
  Auth's. Device count, platform, last-seen time and IP addresses are
  visible to the server and to Supabase's logs.
- **Edit timing, precisely.** Every HLC carries the wall-clock millisecond
  and the device id, so the server sees when each column of each row was
  last written, and by which device.
- **Shape.** Row counts per table, columns per row, which columns change
  together and how often. The table names are hashed, but the largest table
  is plainly `tasks` and a row with a column that changes once and never
  again looks like a completion. A habit's daily contribution rows give away
  the rhythm of the habit, though not what it is.
- **Sizes**, to within a padding bucket. A long note is visibly long.
- **Equality.** Two writes to the same row are visibly the same row (that is
  what makes the merge possible), and derived ids are equal across devices
  by design.
- **Deletes and their timing.**

It does not leak relationships between rows: foreign keys are values, and
values are sealed.

### What it rules out

The current server reads no value, so nothing that ships today is lost.
What it closes off:

- **Anything server-side that needs content**: reminders or push
  notifications that say what is due, email digests, a server-side import
  (Checkvist, Google Tasks), server-side search, an assistant running against
  the account without a device. Reminders stay local notifications scheduled
  by each device.
- **Sharing a list with another account.** That needs per-list keys wrapped
  to each member's public key and is a separate design.
- **A web client** without the user typing the phrase into it.
- **Support recovering an account's data.** Only a device or the phrase can.

---

## Step 2: the merge in Postgres, Realtime, and no Railway

### Schemas and roles

The tables stay in `sync`, which the Data API does not expose, with RLS on
and no policies, so no client role can ever select or write them directly.
That is stricter than LibreLog, which grants `select` on two tables.

The functions the apps call go in a new schema, `takt_api`, which is added
to the project's exposed schemas. Each is `security definer`, owned by
`postgres`, with `set search_path = ''` and fully qualified names, takes the
account from `auth.uid()` (LibreLog's `require_user`) and checks that the
device it is given belongs to that account (`require_device`). `execute` is
revoked from `public` and `anon` and granted to `authenticated` only.
Errors use PostgREST's `PTxxx` codes so the HTTP status means what it does
now, as LibreLog does.

| Function | Replaces |
| --- | --- |
| `register_device(device_id, name_enc, platform)` returns the account state (epoch, key check) | `POST /v1/devices` |
| `account()` returns devices | `GET /v1/account` (the email comes from the app's own Supabase session) |
| `push(device_id, epoch, changes jsonb)` returns the cursor | `POST /v1/push` |
| `changes(device_id, epoch, since, lim)` | `GET /v1/changes`, without `wait` |
| `begin_epoch(device_id, epoch, key_check, through_cursor)` | step 1's begin |
| `pairing_open`, `pairing_fulfil`, `pairing_take` | step 1's pairing endpoints |
| `sign_out(device_id)` | `POST /v1/sign-out` |
| `delete_account()` | `POST /v1/account/delete`; deletes from `auth.users` as LibreLog's does, so the secret key is no longer needed anywhere |

The `sync` tables gain foreign keys to `auth.users(id) on delete cascade`.
The initial migration deliberately had none, so it would run on any
Postgres; with the server gone, the schema only ever runs on Supabase.

### The merge in plpgsql

`push` does what `push.rs` does, in the same order:

1. Validate the whole batch first (lengths, HLC format, value types, and
   step 1's shape check when the account is encrypted), so a batch is
   applied whole or refused whole.
2. `pg_advisory_xact_lock(hashtextextended('push:' || account, 0))`, the
   same lock the Rust server takes.
3. For each change, `select … for update` the row, then `merge.rs`'s rule:
   for an upsert, each key of `values` wins if `col_hlc ->> key` is null or
   older; a deleted row comes back only for a newer stamp; a delete wins only
   over every column stamp. Changed rows are written with
   `nextval('sync.row_seq')`.
4. Notify (below) and return the account's highest `seq`.

**Every HLC comparison is `collate "C"`.** Rust compares bytes; a Postgres
`text` comparison uses the database's collation, which can treat `-` as
ignorable and compare case-insensitively at its first level. HLCs are fixed
width, so the default collation probably orders them correctly, but
"probably" is not a merge rule.

**Serialisation and `seq` stay as they are.** The global sequence plus a
per-account lock held from before the first `nextval` to commit is what the
cursor already relies on. LibreLog instead takes a row lock on
`accounts.last_seq` and numbers each account gap-free. Takt keeps its
scheme, because during the cutover the Rust server and the function write
the same table side by side, and they only serialise against each other if
they take the same lock and draw from the same sequence. Every cursor a
device holds stays valid across the cutover, so no device resyncs.

**One rule, two implementations.** While Railway runs, the merge exists in
Rust and in plpgsql. `merge.rs` stays as the reference: a test there writes
its cases to a fixture (`sync-server/rules/fixtures/merge_cases.json`:
stored row, change, expected outcome), and the SQL tests replay every case
against `push`. After Railway is gone `merge.rs` has no caller in
production, but it remains the executable specification the SQL is held to.

The SQL tests follow LibreLog's `supabase/tests/run.sh`: a throwaway Postgres
with stub `auth.uid()` and `realtime.send()`, the migrations applied, then
`sync_test.sql` with the merge cases, RLS checks (an `authenticated` role
cannot select `sync.rows`; one account's function calls never see another's
rows) and the error codes.

### Realtime instead of the long poll

`push` ends by calling a helper, `sync.notify_account(account, cursor)`,
which does `realtime.send(jsonb_build_object('cursor', cursor), 'rows',
'account:' || account, true)` on a private channel and `pg_notify('rows_changed',
'')`. During the cutover the Rust server's `push` calls the same helper,
so a device on either transport hears about either kind of push. Realtime
delivers the message after the transaction commits.

A policy on `realtime.messages`, as LibreLog's
`20261003150200_realtime_auth.sql`, lets an `authenticated` user receive
broadcasts on `account:<their uid>` only, and there is no insert policy, so
no client can send on it. *Allow public access* in the project's Realtime
settings is turned off, so only private channels work. The message carries
a cursor and nothing else.

On the client, the long-poll loop is replaced by a subscription while the
app is in front: a message pulls; every (re)subscribe pulls once, since
messages sent while disconnected are not replayed; and a pull runs every
five minutes as a safety net. The other triggers stay: coming to the
foreground, 2 s after the last local write, and background refresh. The Mac
and iPhone add supabase-swift's `Realtime` product beside `Auth`; Android adds
supabase-kt's `realtime-kt` beside `auth-kt`. The token the channel joins
with is refreshed when the session refreshes.

The function calls themselves stay with each platform's own HTTP client, as
now and as in LibreLog: the core makes the RPC's JSON arguments and reads
its answer, the transport posts to `<supabase>/rest/v1/rpc/<name>` with the
publishable key, the bearer token and `Content-Profile: takt_api`. The core's
error reading (`sync_server_message`, `sync_failure_message`) learns
PostgREST's `{"code","message"}` shape beside the server's `{"error"}`.

### Limits and abuse

Anyone can make an account, and with E2E nobody can look at what an
account stores, so the functions bound it themselves:

- **Batch**: at most 500 changes and about 1 MB per push. `prepare_push`
  batches by count today; it also needs a byte budget.
- **Cell**: a sealed value over 64 KiB is refused (`PT413`).
- **Quota**: `accounts.bytes_used`, kept up to date by `push` from the size
  change of each row it writes, with a default quota of 50 MB, ten times
  the largest real account. `PT413` over it.
- **Rate**: a fixed window on the account row, about 120 pushes a minute,
  `PT429` past it. `changes` needs none beyond PostgREST's own.
- **Sign-up**: Supabase Auth's own rate limits, and its CAPTCHA option if
  sign-ups are ever abused.
- **Time**: the `authenticated` role's statement timeout on Supabase is
  8 s. A 500-change push is a few hundred row reads and writes; measure it
  in the SQL tests against a large account and keep batches well under.

A nightly `pg_cron` job (LibreLog's `maintenance()` shape) deletes expired
pairings, deletes a plaintext epoch-0 feed once step 1's conditions are met,
and recounts `bytes_used`.

### Free tier

Check the numbers against Supabase's pricing page at cutover; as of writing,
the free plan gives:

- **500 MB of database.** About a hundred accounts the size of the one
  measured above.
- **200 concurrent Realtime connections, 2 million messages a month.** One
  connection per foreground device. A push to an account with three devices
  in front is one send and three deliveries. The long poll already held one
  connection per foreground device on Railway, so the shape is unchanged.
- **No pausing while in use; pausing after seven days with no requests.**
  If every device is idle for a week the project pauses and sync fails until
  it is restored from the dashboard. The Railway server never kept it awake
  either.
- **No automatic backups.** Every device holds a full copy, and a backup of
  ciphertext is only as useful as the key.

### Cutover, so no device is stranded

1. **Apply the migrations** to the live project: functions, the helper,
   the Realtime policy, the cron job. They work on the existing tables,
   beside the Railway server. Deploy the Railway server's change to call
   `sync.notify_account`.
2. **Ship clients that prefer the functions.** On launch a client calls
   `register_device`; if PostgREST says the function does not exist
   (`PGRST202`, a self-hosted project without the migrations), it uses the
   HTTP server as before. Both paths record `devices.protocol`.
3. **Wait** until every device seen in the last 30 days reports the new
   protocol. For the one account that exists now, that is the Mac, the
   iPhone and the Android phone updating.
4. **Turn Railway off**: `railway down`, then delete the `priority-sync`
   project, including the Postgres service in it that has been unused since
   2026-10-03. A device still on an old build then sees "couldn't reach the
   sync server" until it updates. It loses nothing; its outbox waits.
5. **Remove the fallback** from the clients and the server from the repo
   (below), in a release after step 4.

### Self-hosting gets simpler

A self-hosted pair becomes a self-hosted Supabase project: create it, run
`supabase db push` with this repo's migrations, enter its URL and
publishable key in the app. There is no server to run and no secret key to
handle. `SyncEndpointsRecord.server_url` goes; a typed endpoint that still
names a server keeps working until step 5 and is then read for its Supabase
half only. `docs/self-hosting.md` is rewritten around that.

### What leaves the repo

`sync-server/src`, `tests/api.rs`, `Dockerfile`, `Caddyfile`,
`docker-compose.yml`, `railway.toml`, `static/privacy.html` (the privacy
policy moves to wherever the store listings point), and the sqlx migration,
which becomes the first file of `supabase/migrations/` as a `create … if not
exists` baseline. `takt-sync-rules` stays: the core depends on it for the
clock and the wire structs. It moves to `sync-rules/` at the root, since it
was only inside `sync-server/` because Railway built from that directory.
That move changes `core/Cargo.toml`, the CI job that tests it, and the
`sync-server/rules` mentions in `CLAUDE.md`.

---

## Either order works

The steps are written to be independent. Doing step 2 first moves
plaintext rows through functions instead of the server, and step 1 then adds
epochs, pairing and the shape check to SQL. Doing step 1 first writes those
three things in Rust on Railway and then again in SQL. See the open
questions.

## Why not LibreLog's op log

LibreLog's server stores sealed batches of ops in sequence and merges
nothing; each device merges by HLC as it applies them. That leaks less (no
per-row structure, no column-level timing) and its server is simpler. Takt
does not adopt it now because Takt's devices keep no per-column clocks: the
merged state with its clocks lives on the server, and the client applies
already-merged rows. An op log would need per-column clocks in every local
table, a client-side merge, snapshots and compaction. That is a larger
change than this plan's two steps together. If the leakage above matters
more later, it is the step after this one, and the epoch machinery is how an
account would move onto it.

## Risks

- **The merge in two languages.** Mitigated by the shared cases above.
  Without them the first bug would be a silent divergence between devices.
- **HLC ordering under a collation.** Covered by `collate "C"` and a test
  with HLCs that differ only in a hyphen-separated field.
- **A half-finished conversion.** The converter's outbox is durable, but if
  it is never launched again, the encrypted feed stays partial. Every other
  device still holds the full workspace locally, and settings on an
  encrypted device offers *Upload this device's copy*, which enqueues a
  snapshot; offer it with a warning, because a device that is behind pushes
  stale values with newer clocks.
- **Two devices converting at once.** The second `begin_epoch` finds the
  account already at epoch 1 and becomes a joining device; its key is
  discarded unused. The key check decides which key is the account's.
- **A device away longer than the plaintext feed is kept.** It cannot drain
  deletes it missed, and keeps rows deleted elsewhere until it replaces its
  copy. The settings page names the device and the date.
- **Old builds stuck on the message.** By design; the cost is that a phone
  nobody updates stops syncing. With Play internal testing and TestFlight
  this is the user's own devices.
- **Realtime misses a message.** The pull on subscribe and the five-minute
  pull bound the delay.
- **Exposing a schema by mistake.** If `sync` were ever added to the exposed
  schemas, RLS with no policies still refuses every client role; a SQL test
  asserts it.
- **Crypto mistakes.** Audited RustCrypto and BLAKE3 crates, LibreLog's
  format, purpose separation by context, and the same tests LibreLog has
  (wrong key, tampering, cross-purpose, cross-cell associated data). The one
  new construction is AES-SIV, used as specified, not built.
- **Key revocation.** Revoking a lost device stops it pushing but not
  reading what it already has or decrypting what it pulls if it still has a
  session. Real revocation is a key rotation: a new epoch, by the same
  procedure. Out of scope here, but nothing above blocks it.

## Open questions

1. **Is encryption mandatory?** Recommendation: yes. New accounts are
   encrypted from the start, the one existing account converts once, and
   there is no way to turn it off. One code path, and no plaintext mode to
   keep working.
2. **Hash table and column names, or leave them readable?** Recommendation:
   hash them. The shape leaks anyway, but it costs almost nothing, because
   clients already ignore names they do not know.
3. **Which step first?** Recommendation: step 2 first, unless the privacy
   win is wanted soon. It means epochs, pairing and the plaintext refusal are
   written once, in SQL, instead of in Rust and then SQL, and it removes the
   Railway bill sooner.
4. **Share the crypto with LibreLog as a crate, or copy it?**
   Recommendation: copy the ~380 lines into `core/src/sync/crypto.rs` with
   Takt's contexts and the same sealed format. A shared crate (a git
   dependency both cores pin) is worth it when a third app needs it; until
   then it couples two release cycles for little.
5. **Keep self-hosting?** Recommendation: yes, as "your own Supabase
   project", which step 2 makes easier. Drop the custom server URL. Is anyone
   known to be self-hosting the Railway-style server now?
6. **How long to keep the plaintext feed?** Recommendation: until every
   device seen in 30 days has moved, at most 30 days, with *Remove now* in
   settings. For the one existing account, remove it by hand as soon as the
   three devices have moved.
7. **Pairing in both directions?** Recommendation: yes. The Mac has no
   practical camera, so it always shows the code and the phone always scans,
   whichever of them is new.
8. **Sync the key through iCloud Keychain between the Mac and iPhone?**
   Recommendation: no. The Mac cannot (no provisioning profile), it would not
   reach Android, and it would put the key in Apple's escrow.
9. **Derive the key from the account password instead of a phrase?**
   Recommendation: no. Google and Apple accounts have no password, a reset by
   email would orphan the key, and Supabase sees the password at sign-in.
10. **Stay on the free Supabase plan?** Recommendation: yes while the only
    account is yours; move the project to a Pro org before inviting others,
    for backups and no pausing. Transfer keeps the URL and keys.

## Commits

Each commit is green on its own, in this order. Gates are the ones in
`CLAUDE.md`; "core gates" means `cargo test`, `clippy -D warnings` and
`fmt --check` on `core/`, `scripts/build_core_apple.sh`, `swift test --filter
TaktRustCoreTests` and Android's `:data:testDebugUnitTest`, with the
regenerated bindings committed. "Mac gates" means `xcodebuild`, `swift
test`, `swiftlint lint` and `./scripts/install_local.sh`; "iPhone gates"
`xcodegen generate`, `build-for-testing` and `./scripts/install_ios.sh`;
"Android gates" the full Gradle line and `./scripts/install_android.sh`.
Any commit that changes the core is followed by `./scripts/install_cli.sh`,
because the CLI opens the same database through the core and must know its
migrations.

**Step 1**

1. `feat(core): a sync key, its recovery phrase and pairing, and sealed
   column values` (`core/src/sync/crypto.rs`, `SyncKey`). Core gates, then
   Mac, iPhone and Android gates for the new bindings.
2. `feat(sync-server): accounts, epochs, pairing and refusing plaintext
   once an account is encrypted` (a new sqlx migration; `takt-sync-rules`
   wire gains `epoch`). Server gates (`cargo test --workspace` with a local
   Postgres, clippy, fmt), and core gates because the rules crate changed.
   Deploy before any client uses it; it changes nothing for epoch 0.
3. `feat(core): push and pull sealed rows under an epoch` (`prepare_push`,
   `SyncPull`, `apply_pull` take the key; `v30_sync_epoch` adds
   `sync_state.epoch`; `sync::begin_epoch`). Core gates,
   `scripts/dump_workspace_schema.sh` with the fixture committed, then Mac,
   iPhone and Android gates.
4. `feat(sync): the sync key in the Keychain, pairing and the recovery
   phrase on the Mac and iPhone`. Mac and iPhone gates.
5. `feat(android): the sync key in the Keystore, pairing and the recovery
   phrase`. Android gates.
6. `feat(sync): turn on end-to-end encryption, and join an encrypted
   account` (the conversion and the joining path on all three, kept last so
   the capability ships before the switch). Mac, iPhone and Android gates.
7. `docs(sync): end-to-end encryption` (`docs/sync.md`,
   `docs/self-hosting.md`, the privacy policy).

**Step 2**

8. `test(sync-rules): write the merge cases to a fixture`. Rules and core
   gates.
9. `feat(supabase): the sync schema baseline, the merge as a function,
   Realtime pings and nightly maintenance` (`supabase/migrations/`,
   `supabase/tests/`). `supabase/tests/run.sh`; server gates, because the
   server's integration tests now run against the migrated schema.
10. `feat(sync-server): notify through sync.notify_account`. Server gates.
11. `feat(core): function arguments and PostgREST errors`. Core gates, then
    Mac, iPhone and Android gates.
12. `feat(sync): call Supabase directly and listen on Realtime on the Mac
    and iPhone, falling back to the server`. Mac and iPhone gates.
13. `feat(android): call Supabase directly and listen on Realtime, falling
    back to the server`. Android gates.
14. *(after the cutover)* `chore(sync): retire the Railway server` (remove
    the server and the fallback, move `takt-sync-rules` to `sync-rules/`,
    drop `server_url`). Core gates, rules gates, `supabase/tests/run.sh`,
    then Mac, iPhone and Android gates;
    update `CLAUDE.md` and CI in the same commit.
15. `docs(sync): sync is Supabase alone`.

Outside the repo, at their points in that order: deploying commit 2 and
commit 10 to Railway; `supabase db push` for commit 9 after linking the
project; adding `takt_api` to the exposed schemas and turning off Realtime's
public access in the dashboard; and, after step 4 of the cutover, deleting
the Railway project.
