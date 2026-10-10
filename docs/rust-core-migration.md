# Rust core migration

Decided 2026-10-07: the workspace logic moves into one Rust crate,
`takt-core`, which every client calls. The interfaces stay native: SwiftUI on
the Mac and iPhone, Compose on Android, ratatui in the terminal. This file is
the plan; tick steps off here as they land.

## Why

The same store is written three times, and the copies drift.

| Copy | Where | Lines (2026-10-08) |
|---|---|---|
| Swift store and sync | `Sources/TaktWorkspace`, `Sources/TaktSync` | ~7,750 |
| Rust CLI writes | `cli/src/workspace*.rs` | ~2,860 |
| Kotlin store and sync | `mobile/android/data` | ~5,680 |

The 2026-10-07 audit found the drift this causes. The Mac had no SQLite busy
timeout while the CLI did. Sibling ordering lacked the CLI's `id` tiebreak. A
cross-list move journalled its rows differently on the server. Each fix had
to be made, and tested, up to three times. With one crate it is made once.

## Shape

```
core/                     takt-core: a library crate, no I/O beyond SQLite
  src/schema.rs           migrations, one ordered list (today: WorkspaceStore+Migrations.swift, WorkspaceSchema.kt)
  src/store/*.rs          write paths, one module per WorkspaceStore extension
  src/journal.rs          undo_control / change_log
  src/sync/*.rs           HLC, push/pull, merge (shared with sync-server)
  src/ffi.rs              UniFFI surface: records, errors, a Store object
cli/                      depends on core directly; workspace_tasks.rs shrinks to calls
sync-server/              depends on core's sync/merge types directly
Sources/TaktCoreFFI/      generated Swift bindings + the xcframework, linked by Mac and iPhone
mobile/android/core-ffi/  generated Kotlin bindings + the .so per ABI
```

A Cargo workspace at the root holds `core`, `cli` and `sync-server`, so all
three build against one lockfile.

**Database access.** The crate owns the connection, through `rusqlite` with
the bundled SQLite, so every platform runs the same SQLite version and the
same pragmas: WAL, a five-second busy timeout, foreign keys. Swift no longer
opens the file through GRDB at all.

**Change notification.** The apps poll `PRAGMA data_version` on the core's
own connection (`CoreWorkspace.dataVersion`). Every write of theirs goes
through that connection, which does not count its own commits, so the number
moves only for another process, with no "ignore our own writes" bookkeeping.

**Threading.** The `Store` object is `Send + Sync` behind a connection pool.
Swift calls it from a background executor and hops to the main actor with
the result, as `WorkspaceStore` callers already do.

## Order

Each step is one or more green commits. A step is done when the moved
behaviour has one implementation, and the Swift, Kotlin and cargo tests that
covered the old copies pass against it.

1. **Scaffold. Done 2026-10-08.** `core/` is the `takt-core` crate with
   UniFFI. `scripts/build_core_apple.sh` builds the xcframework and the Swift
   bindings (`Sources/TaktRustCore`). The data module's `buildRustCore`
   Gradle task runs `scripts/build_core_android.sh` for the `.so` files and
   the Kotlin bindings (`uniffi.takt_core`). One call, `coreVersion()`,
   crosses both bindings. It is shown in the Mac's Diagnostics and in
   Android's Settings, where a minified release on an emulator read it. It is
   tested by `TaktRustCoreTests` and `TaktCoreTest.kt`. CI builds the core
   before every Swift job and lints and tests it in a `core` job. There is
   no root Cargo workspace: `cli/target/release` is where the installed
   `takt` symlink points, and a workspace would move every crate's `target`
   to the root.
2. **Schema and migrations. Done 2026-10-08.** `core/src/schema` holds the
   twenty migrations. Their SQL was captured from GRDB's migrator as it ran,
   so it was not retyped. The three steps that walk existing rows (v11, v12,
   v13) are ported by hand and tested. Progress stays in GRDB's
   `grdb_migrations` table under the same identifiers. The Mac and iPhone
   call `migrateWorkspace` before GRDB opens its pool. Android calls it
   before the androidx driver opens the file. The Swift migrator and
   Kotlin's migration steps are deleted. `scripts/dump_workspace_schema.sh`
   generates the fixture from the core, and a core test holds a new database
   to it byte for byte. On a backup of the real database the core applied
   nothing and changed nothing; on an Android emulator a release build
   opened an existing install through it and saved a task.
   `core/src/schema/triggers.rs` generates the journal and outbox triggers,
   matching all 69 in the fixture, for the next migration that needs them.
3. **Undo journal. Done 2026-10-08.** `core/src/journal.rs` holds undo,
   redo, the labels, the history and the history target, and `begin` and
   `finish`, which arm and settle a step inside a caller's transaction. The
   Mac, iPhone and Android call undo, redo and the reads through
   `CoreWorkspace`, the handle `core/src/workspace.rs` exports: one
   connection beside the client's own, on the same SQLite library. The CLI
   links the core and brackets its writes with `begin` and `finish`. The
   triggers moved in step two. What stays duplicated is `journalledWrite` in
   Swift and Kotlin: it has to run inside the client's own transaction, so it
   goes when the writes it wraps move in step four. Because the core writes
   on its own connection, the Mac takes in the new `data_version` after each
   `perform`, and Android's `WorkspaceDatabase.coreWrite` announces the
   changed tables itself.
4. **Task writes. Done 2026-10-08.** Every journalled write is in the core,
   and the Swift store, the Kotlin repository and the CLI call it: `tasks.rs`
   (create, delete, move, nudge, drop, indent, outdent, board column,
   matrix, status with the next occurrence), `lists.rs` (folders and lists,
   their settings sheets), `conversions.rs` (tasks to lists and back,
   nested-list flags, boards), `editor.rs` (the task editor and planning),
   `conditions.rs`, `dailies.rs`, `habits.rs` (with `HabitPolicy`),
   `today.rs` (focus order, planning for today), `waiting.rs` (waiting and
   follow-ups), `focus.rs` (sessions, with the candidate read and
   `TaskAvailabilityPolicy`) and `periodic.rs` (`PeriodicSchedule`). Each
   takes the caller's transaction, so the CLI journals it under "MCP: ";
   `CoreWorkspace` journals it for the apps. `journalledWrite` is gone from
   both apps. Their own core commits are kept out of their external-change
   tokens.
5. **The rest of the writes. Done 2026-10-08.** Bootstrap and the Inbox,
   themes and preferences (`setup.rs`), the Checkvist import, the
   plugin-era dailies and the board baseline (`imports.rs`) are in the core.
   No client opens a write transaction of its own any more, except
   Android's benchmark fixture. The CLI's workspace writes call the same
   functions, so it no longer copies Swift row for row; a real-data run
   against a copy of the live database (add, rename, link, waiting with a
   past follow-up, complete, task to list, delete) left it consistent.
6. **Reads. Done 2026-10-08.** Every read the Mac, iPhone and Android make
   is the core's. `records.rs` holds the task, list, folder and workspace
   rows, the outline and the visible-root reads; `search.rs` the FTS prefix
   search with titles weighted over notes; `rows.rs` dailies and what a day
   shows, the completion streak, conditions, metadata, focus sessions and
   queues, work blocks, awards and points, themes, preferences, boards and
   counts; `editor.rs` the editor snapshot. Each client keeps its record
   types and its small in-memory trees (`WorkspaceListTree`) over the core's
   rows, so screens did not change. Android's `Db` reaches the core, so the
   helpers its repository shares switched in place.
   **The next-up ranking (2026-10-08).** `core/src/ranking.rs` holds
   `NextUpSelector.evaluate` and `score`; `focus.rs` holds the candidate read
   and `TaskAvailabilityPolicy`. Swift's `TaktCore` and Kotlin's `:core`
   keep their types and wrap the core, so their callers did not change; the
   Kotlin bindings moved into `:core` for it. On a seeded 5,000-task
   workspace on the JVM, the whole next-up snapshot went from 37.7 ms to
   18.2 ms: the core's candidate read is 7.1 ms against Kotlin's 31.9 ms,
   while ranking 2,496 candidates costs 6.8 ms against 3.8 ms, most of it
   the crossing.
7. **Sync engine. Done 2026-10-08.** `core/src/sync.rs` holds the pairing
   state, the snapshot, the outbox coalesced per row, acknowledging, and
   applying a pull (local edits win until pushed, unique-key rivals resolved
   the same way on every device, a second workspace folded in, orphans
   removed). The Mac, iPhone and Android call it. The hybrid logical clock
   and the server's merge are one crate, `takt-sync-rules`, in
   `sync-server/rules/`: the server merges with it, and the core depends on
   it and exports `hlc_tick` and `hlc_receive`, which Swift's and Kotlin's
   `HybridLogicalClock` wrap. It lives inside `sync-server/` because Railway
   builds the server from that directory alone; the server's `Cargo.toml`
   makes it a workspace member, so both share one lockfile. What stays in
   each client is the transport: HTTP, auth and the long poll, which are
   platform code by nature.
8. **Remove the copies.** Delete GRDB from the package, the Kotlin
   repository bodies and the CLI's store code. `TaktWorkspace` becomes a thin
   Swift wrapper over the generated bindings.
   **GRDB is gone (2026-10-08).** `WorkspaceStore` holds one `CoreWorkspace`
   and nothing else; the records lost their GRDB conformances; the
   external-change token is the core connection's `data_version`, on the Mac
   and on Android, so neither keeps count of its own commits any more. Tests
   that play another process open the file through `test-support/sqlite`.
9. **Pure logic.** The engines still implemented twice, in Swift's
   `TaktCore` and Kotlin's `:core`, move into the core; each platform keeps
   its types and signatures and wraps the core's function, so callers did
   not change, and the old Swift and Kotlin suites still run as the oracle.

   **Recurrence, habits and dailies.** `core/src/recurrence.rs` exports the
   rules the writes already used: `PeriodicSchedule`'s parsing and next
   occurrence (`periodic.rs`), `HabitPolicy`'s scheduled day, expiry, carried
   appearance, reconciled column and Habits list id (`habits.rs`),
   `WaitingFollowUp`'s due follow-up, title, tag and id (`waiting.rs`), and
   whether a daily is due, both the workspace's (`WorkspaceDaily.isDue`) and
   the plugin era's (`Daily.isDue`, whose cycle runs backwards from its
   anchor too), in `dailies.rs`; the CLI's dailies file reader calls the
   latter as well, so that rule has one copy instead of three. The Swift and
   Kotlin suites are ported as Rust tests in `core/src/recurrence/tests.rs`.
   Two drifts were settled for Swift: the core clipped a waiting tag to 40
   Unicode scalars where both apps clip to 40 grapheme clusters (it now uses
   `unicode-segmentation`), and a cadence that cannot land (an overflowing
   interval) returns none instead of panicking. Left native on purpose:
   `DayBoundary`, which `DayLogAggregator` calls once per log event, where a
   crossing would cost several times the Calendar arithmetic it replaces;
   the display strings (`displayLabel`, `scheduleLabel`, `HabitFrequency`'s
   labels, and `WaitingFollowUp.label`, `dateTimeText` and `editableText`,
   which are locale formatting asked for by every waiting card); the
   capture-word parsing `HabitPolicy` borrows from `TaskCaptureToken`, which
   belongs with the capture syntax; and `DailyCollection`'s ordering and
   editing, which is plain list bookkeeping.

   **Focus and progress (2026-10-10).** `core/src/progress.rs` holds the
   focus timeline's layout and per-task summaries (`FocusDayTimeline`), today
   against the week (`WorkProgressSummary`), the progress graph's days
   (`TaskProgressSeries`), finished work by day (`CompletedWorkDigest`), the
   stale-session rule (`StaleFocusPolicy`), block scoring (`FocusPoints`
   minutes, clamp and score, which `focus::finish_block` now uses too, so the
   prompt's preview and the stored award are one sum) and the completion
   milestone's precedence (`CompletionMilestonePolicy.milestone`). Swift and
   Kotlin keep their types and signatures and wrap it; Kotlin's
   `DayPlanSelector` now calls `plan_day` as Swift's already did. Each call
   passes its inputs once and gets back numbers or indices into what it
   passed, so titles and items never cross back. Two read straight from the
   rows: `CoreWorkspace.work_progress` (the Mac's and Android's weekly totals,
   which used to fetch the week's blocks and completions across) and
   `resolve_stale_focus_session`, which reads the session, applies the rule
   and closes or discards it in the core. Time zone maths is chrono-tz with
   the caller's zone name, as in `periodic.rs`. One platform difference:
   Kotlin kept a paused session with no task until the day was over, Swift
   discarded it at once; Swift's rule won. What stays native: the number
   format (`FocusPoints.formatted`), the quality presets, the celebration
   durations and `CelebrationRowTreatment`, which are presentation, and
   `DayLogAggregator`, which works over the Mac's own JSON event log rather
   than the database, exists on one platform, and would cross every event of
   that log on every completion. The CLI's `focus_history` is a plain sum of
   rows and stayed as it was.

   **Boards, outlines and the matrix (2026-10-10).** The sidebar's order is
   `sidebar/outline.rs`: `WorkspaceSidebarOutline.rows` and `listIDs` in
   Swift and Kotlin wrap it, and each row crosses back as a kind and an
   index into what was passed, so no string is copied back. The Mac keeps
   its Today row and its wrapping cursor; the phone asks without Today and
   keeps its clamped cursor, the one place the two copies had disagreed.
   A 137-row sidebar costs the same as before, 0.4 ms a build in a debug
   test. Android's sidebar read every active list's tasks one list at a
   time and walked them in Kotlin for its nested lists and badges;
   `sidebar_index_with_open_counts` walks them in the core, so only the
   nested lists and the numbers cross: 26 ms to 11 ms on a 5,000-task list
   on the JVM. The Mac draws totals, not open counts, so its
   `sidebar_index` skips the status read that cost it a tenth (5.4 ms
   against 5.0 ms on the 7,000-task benchmark) and stays at 5.0 ms. The rest
   of the cluster stays native, measured on the same benchmark.
   `TaskOutlineFolding` (both platforms) folds an outline the screen holds
   against fold state that lives only in memory, 0.04 ms for a list's
   outline, against 6 to 10 µs a row to cross. `MatrixGeometry`,
   `MatrixQuadrant` and `RootDueBucket` are per-point maths and display
   names. `WorkspaceListTree` is the small tree over the core's rows step 6
   kept; its `WorkspaceSidebarIndex` and `WorkspaceBoardTrees` builders
   stay as the oracles the core's `sidebar.rs` and `board.rs` are tested
   against. Android's board still shapes the trees its outline read in the
   same scope, as the Mac's single-list board does, because reading them
   again in the core would cross the same rows twice. Kotlin's
   `KanbanColumn` has no caller outside its tests. The Swift-only engines
   work on the Checkvist-era tasks `TaskListViewModel` and `KanbanManager`
   keep in memory, which the core never holds: `KanbanFilter`,
   `KanbanSelection`, `KanbanManualOrder`, `TaskVisibilityEngine`,
   `TaskFilterEngine`, `MatrixClustering` and `MatrixSpread`.
   `MatrixNavigation` and `MatrixViewport` have no callers outside their
   tests. `BoardLinks` solves the board's link geometry from measured card
   heights a frame at a time. It overlaps `board.rs` only in which card a
   subtask hangs from, which the board read already carries.

Pure-logic engines in `TaktCore` (the command parser, recurrence, visibility,
theming) stay in Swift until steps 1 to 8 are done. They are not duplicated
on Android in the same way, so moving them buys less.

## Risks

- **App size and build time.** An app build already needs cargo for the
  bundled CLI, so the toolchain is not new. The core adds an xcframework
  with arm64 and x86_64 slices for macOS and for the iOS simulator and
  device.
- **iOS widgets.** The widget extension does not open the store today; it
  imports only SwiftUI, WidgetKit, AppIntents and ActivityKit. Keep it that
  way, so the extension never has to link the core.
- **Android ABIs.** Build arm64-v8a and x86_64; the user's phone is arm64.
- **FFI cost on hot reads. Measured 2026-10-09.** One call per refresh was
  not enough: each row crossing UniFFI costs about 8 to 10 µs, which is more
  than the work done on it. Moving logic into the core pays only when fewer
  rows cross. On a seeded 7,000-task workspace
  (`workspace-tests/WorkspacePerformanceBenchmarks.swift`,
  `core/examples/perf_reads.rs`):
  - The sidebar (`sidebar.rs`) walks every list in the core and returns only
    the nested lists and one count per list. It used to fetch every task. The
    sidebar's read went from 93 ms to 5 ms, and the main-thread refresh after
    one edit from 81 ms to 8 ms.
  - Next up (`next_up.rs`) reads the candidates, plans the day
    (`DayPlanSelector` now wraps `next_up::plan`) and ranks them in one
    call. The Mac and the iPhone's Today and widget keep only the first
    eight ranked tasks and the day's own tasks. The snapshot went from
    69 ms to 14 ms; without a limit, as the iPhone's focus screen asks, it
    is 34 ms.
  - Its reads use a second, `query_only` connection on the same file, so a
    main-thread read no longer waits behind it. Measured while a snapshot
    runs, the worst such read went from 4.6 ms to 1.8 ms. Writes,
    `data_version` and the journal stay on the first connection, so the
    external-change token still ignores the app's own commits.
  - The waiting chips and the planning values read only the metadata rows
    that carry them (`waiting_metadata`, `planning_metadata`): 5 ms each
    down to 0.03 ms. The Mac rereads the chips only when
    `WorkspaceStore.changeStamp()` has moved, so switching lists skips the
    reread.
  - A combined scope's board (`board.rs`), Everything's or a folder's,
    selects the actionable cards, walks every card's tree, names every
    parent and carries each drawn row's column and matrix place in one
    call. Finished rows the pane would hide outright stay in the core, and
    the tree indexes cross as packed `u32` bytes rather than one value at a
    time. The board refresh after one edit went from 92 ms to 68 ms. What
    was left was the cards themselves: the board draws all 6,594 of them,
    and as records they cost about 6 µs each to cross, some 42 ms of the
    60 ms read. `tasks_in_lists` reads its columns by position now, which
    took its own Rust time from 20 ms to 10 ms. A single list's board still
    shapes the tree the outline has already read that refresh, since
    reading it again in the core would cross the same rows twice.
  - Those 6 µs were UniFFI's Swift side, not the core: it reads a record
    field by field out of `Data`, a bounds-checked copy per integer and a
    fresh `[UInt8]` per string, and a `TaskRow` has seventeen fields, nine
    of them strings or optional strings. So the big row reads cross as one
    buffer (`packed_rows.rs`: a presence bitmask, the integers, then
    length-prefixed UTF-8), which `PackedTaskRows` in Swift decodes in one
    pass over raw memory, sharing one string for a run of rows from the
    same list. The board's `rows` cross that way, and the Mac's `listTrees`
    reads `tasks_in_lists_packed`; the record `tasks_in_lists` stays for
    anything else. The views see the same `WorkspaceTask`s; a test holds
    the packed decoding to the record path. Measured 2026-10-09: the
    combined board's read went from 62 ms to 21 ms (the crossing alone
    from 56 ms to 16 ms), the board refresh after one edit from 77 ms to
    36 ms, every list's trees from 58 ms to 17 ms, one list's from 1.4 ms
    to 0.4 ms, and the single-list refresh after one edit from 63 ms to
    21 ms. Decoding 7,000 rows in Swift takes 2 ms; what remains is the
    core's own reading and walking.
- **Two SQLite libraries in one process. Resolved 2026-10-08.** Two
  copies of SQLite sharing a file can each release the other's POSIX locks
  and corrupt it, so the core never brings a second one into an app. On
  Apple it links the system SQLite, which GRDB uses. On Android it links
  androidx's bundled SQLite: `libsqliteJni.so` exports the whole C API, and
  `scripts/build_core_android.sh` links the core against it, so the core's
  `.so` needs `libsqliteJni.so` and carries no SQLite of its own. The core
  can therefore open the file while the app holds it. Keep the core's
  androidx version and the driver's in step: both come from
  `libs.versions.toml`.
- **Captured triggers are text.** A captured migration's triggers name the
  columns its table had then. Replaying it on a database where a later
  migration already ran would install stale triggers. That cannot happen in
  order, which is the only way migrations apply, but tests that rewind one
  migration must rewind the later ones too.
- **Two writers.** The CLI and each app write the same file through their
  own core connections. The five-second busy timeout on every connection is
  what keeps that safe; do not remove it.
