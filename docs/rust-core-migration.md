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
same pragmas: WAL, a five-second busy timeout, foreign keys. Swift stops
opening the file through GRDB once its last write path has moved.

**Change notification.** The app's `PRAGMA data_version` poll keeps working
unchanged, because writes still land in the same file. Later the core can
expose a callback for its own process's commits, which removes the "ignore
our own writes" special case in `WorkspaceViewModel+ExternalWrites.swift`.

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
4. **Task writes. In progress (2026-10-08).** Each write moves with its tests
   into `core/src/tasks.rs` or `core/src/lists.rs`, takes the caller's
   transaction so the CLI can journal it under its "MCP: " label, and is
   called by the Swift store, the Kotlin repository and the CLI in place of
   their copies. Moved so far: creating, deleting, moving, nudging, dropping,
   indenting and outdenting a task; its board column and matrix place;
   creating, renaming, recolouring, archiving, moving, nudging, dropping and
   deleting lists and folders. Still in Swift and Kotlin: status changes
   (they schedule the next occurrence and expire habits), the task editor's
   save and its planning, conversions between lists and tasks, imports, and
   the dailies, habits, conditions, waiting, today and focus writes. The
   apps' own core commits are kept out of the external-change token by
   `WorkspaceStore.coreWrite` and `WorkspaceDatabase.coreWrite`.
5. **The rest of the writes.** Lists and folders went with step four. Then dailies, habits, waiting and conditions, then
   focus sessions and points.
6. **Reads.** Search with FTS, the today and next-up ranking, outline
   folding. These are the hot paths. Benchmark each against the Swift version
   before switching, using `WorkspaceRepositoryBenchmark.kt` on Android.
7. **Sync engine.** The HLC, push/pull and merge move into `core/src/sync`.
   `sync-server` uses the same merge code, so client and server cannot
   disagree about a conflict.
8. **Remove the copies.** Delete GRDB from the package, the Kotlin
   repository bodies and the CLI's store code. `TaktWorkspace` becomes a thin
   Swift wrapper over the generated bindings.

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
- **FFI cost on hot reads.** Ranking returns whole snapshots, not
  per-task calls, so the boundary is crossed once per refresh.
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
- **Two writers during the move.** Until step 8, Swift's GRDB and the core
  both write the same file. The busy timeout on both sides, added
  2026-10-07, is what keeps that safe. Do not remove it mid-migration.
