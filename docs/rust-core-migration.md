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
2. **Schema and migrations.** Move the ordered migration list into
   `core/src/schema.rs`. Swift's and Kotlin's migrators call it.
   `scripts/dump_workspace_schema.sh` dumps from the core, so the fixture
   is generated, not hand-kept.
3. **Undo journal.** `undo_control` and `change_log` triggers, undo and redo.
   The CLI already holds a Rust copy, so it becomes the core one.
4. **Task writes.** add, update, complete/reopen, move, reparent, delete,
   one at a time, each replacing `WorkspaceStore+Editing`/`+Work` methods,
   `cli/src/workspace_tasks.rs`, and the Kotlin repository method together.
   This is the step that ends the CLI's "copy row for row" rule in
   `CLAUDE.md`.
5. **Lists and folders.** Then dailies, habits, waiting and conditions, then
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
- **Two writers during the move.** Until step 8, Swift's GRDB and the core
  both write the same file. The busy timeout on both sides, added
  2026-10-07, is what keeps that safe. Do not remove it mid-migration.
