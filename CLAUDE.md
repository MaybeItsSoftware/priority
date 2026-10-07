# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Takt (formerly Priority) is a keyboard-first macOS desktop app (macOS 15.6+, Xcode 17+) with a menu bar surface beside it. The code says Takt too — the Xcode project, scheme and targets, the `Takt/` source folder, the Swift modules and the Rust crates — except where the old name is stored data: keychain service names, window autosave names, the iPhone and Android data folders inside their containers, the `X-Priority-Device` sync header, the `PRIORITY_*` runtime environment variables, and the built-in `priority` theme. Its own local workspace is the source of truth; Checkvist is an optional import/integration edge. `DESKTOP_WORKSPACE_ROADMAP.md` is authoritative for where that transition has got to. It is an Xcode app with a Swift Package layered on top — `Package.swift` exposes `TaktCore` (pure logic), `TaktPlugins` (integration plugins), and `TaktAppLogic` (the headless-but-app-bound state machines) as SPM library targets that share source with the Xcode project.

`cli/` is a separate Rust crate producing `takt`. Bare `takt` opens a ratatui terminal UI whose tabs mirror the app's root views; `cli.rs`, `tui/` and `mcp.rs` are three front ends onto the single tool table in `tools.rs`, so none of them can implement behaviour the others lack. It is a command-line peer of the app that talks to the Checkvist API directly and reads the same local files. It also **writes the app's workspace database** (folders, lists, tasks: `cli/src/workspace_tasks.rs`) while the app is running. Each write copies a named `WorkspaceStore` method row for row, and runs under the same `undo_control`/`change_log` journal as an "MCP: …" undo step. The app sees these writes because `WorkspaceViewModel+ExternalWrites.swift` polls `PRAGMA data_version`. So **changing a `WorkspaceStore` write method, or adding a migration, means checking its Rust counterpart** and re-running `scripts/dump_workspace_schema.sh`, which regenerates the tests' schema fixture. See `docs/mcp-server.md`. It shares no source with the Swift side, and the only thing in `Takt/` that may reference it is `MCPServerShim.swift`: the app bundles the CLI as a signed helper at `Contents/Helpers/takt` (see `scripts/bundle_cli.sh`) and `Takt --mcp-server` `execv`s it. That is the app's MCP server — there is no other. Consequently **an app build needs cargo**; set `TAKT_SKIP_CLI_BUNDLE=1` to skip it, at the cost of an app with no MCP server. Its credentials are deliberately its own (`~/.config/takt/config.json`, falling back to the old `~/.config/priority/config.json`; see `cli/src/config.rs`) rather than the app's keychain item, which is reachable only by something carrying the app's code signature. See `docs/cli.md`.

## Build, Run, Test

```bash
# Full app build (the canonical "does it compile" check)
xcodebuild -project 'Takt.xcodeproj' -scheme 'Takt' -configuration Debug -destination 'platform=macOS' build

# Run all SPM unit tests (six test targets, one per library)
swift test

# Run a single test by filter (XCTest style)
swift test --filter TaktCoreTests.CommandEngineCommandParsingTests/testParseSimpleKeywordCommands

# Build + launch the Debug app (kills any running instance first)
./scripts/run.sh

# Produce a release DMG
./scripts/build_dmg.sh <version>

# The Rust CLI
cargo test --manifest-path cli/Cargo.toml
cargo clippy --manifest-path cli/Cargo.toml --all-targets -- -D warnings
cargo fmt --manifest-path cli/Cargo.toml --check
./scripts/install_cli.sh            # release build + a `takt` symlink onto PATH
```

`README.md` is authoritative for keybindings and command palette syntax — consult it when editing `Sources/TaktCore/WorkspaceCommandCatalog+Entries.swift`, `Sources/TaktCore/WorkspaceKeyBindings.swift` or `CommandEngine.swift` so behaviour stays in sync.

## Architectural Layout (Two Build Systems, One Source Tree)

The same files are compiled by two different systems, which is the most important thing to know before editing:

1. **Xcode project** (`Takt.xcodeproj`) — builds the actual macOS app from everything under `Takt/`.
2. **Swift Package** (`Package.swift`) — builds six libraries, three from real directories and three from curated subsets of `Takt/`:
   - `TaktCore` — sources rooted at `Sources/TaktCore/`. Pure, headless logic only (command parser, recurrence, timer policies, the visibility/kanban/shortcut engines). This is what `corelogic-tests/` exercises. **The app links this one** rather than compiling its sources, so everything it uses across that boundary is `public`.
   - `TaktPlugins` — explicit `sources:` list of plugin files plus `plugin-tests-support/PluginModelStubs.swift` (which provides minimal stub models so plugin code compiles without the app shell). Tested by `plugin-tests/`.
   - `TaktAppLogic` — explicit `sources:` list of the app-bound state machines (`TaskRepository`, `TaskMutationService`, `SyncService`, `UndoService`, the offline/priority stores) plus `applogic-support/AppLogicSharedTypes.swift`, which re-declares the Checkvist models rather than making `TaktPlugins` publish them. Tested by `applogic-tests/`.
   - `TaktWorkspace` — sources rooted at `Sources/TaktWorkspace/`: `WorkspaceStore` and its `+*.swift` extensions, the GRDB schema and migrations (`WorkspaceStore+Migrations.swift`), the models. **The app links this one too.** Tested by `workspace-tests/`.
   - `TaktWorkspaceEditing` — `Takt/Editing/`, the task editor drafts. Tested by `workspace-editing-tests/`.
   - `TaktSync` — `Sources/TaktSync/`, the client of `sync-server/`. Linked by the app. Tested by `sync-tests/`.

Consequences when editing:

- `Package.swift` has a large `pluginTargetExcludes` list and explicit `sources:` lists for the two `path: "."` targets. Adding a new plugin or app-logic file requires updating them, or `swift test` starts failing even though Xcode still builds. `Sources/TaktCore/` needs no such bookkeeping — it is a real single-target directory, so a new file there is picked up by both builds.
- `TaktCore` must stay free of AppKit/SwiftUI/UI dependencies — it is consumed by the test target without the app. New declarations there need `public` to be visible to the app, and a `public struct` needs an explicit `public init` (the synthesised memberwise one is internal).
- `TaktPlugins` deliberately excludes each plugin's `+Settings.swift` extension and any service that pulls in app types (e.g. `CheckvistAPIClient.swift`, `ObsidianSyncService.swift`). Keep cross-plugin / app-only types out of the curated `sources:` list.
- `TaktAppLogic` sources must not import AppKit or SwiftUI either. `TaskMutationService` and `SyncService` reach the UI layer through the `TaskMutationHost` / `SyncHost` protocols in `Takt/TaskServiceHosts.swift`; `AppCoordinator` provides the production conformance in `AppCoordinator+ServiceHosts.swift`, which is the app-only side and stays out of the package. Adding a coordinator dependency to either service means adding a host member, not a `weak var coordinator`.
- **A file can only belong to one SPM target.** That still holds for `TaktPlugins` and `TaktAppLogic`, whose sources are compiled by both build systems. What no longer holds is the consequence this file used to draw from it: both targets *can* now `import TaktCore`, because the app links that module rather than compiling its sources, so the import resolves on both sides. `OfflineReplayPolicy.swift` moved into `Sources/TaktCore` accordingly.

## App Composition

- `MainApp.swift` is a near-empty `@main` that installs `AppDelegate` via `NSApplicationDelegateAdaptor`. The activation policy is **not** fixed: `applicationDidFinishLaunching` sets `.regular` because the desktop window is the launch surface, and `applyActivationPolicy(hasOrdinaryWindow:)` drops back to `.accessory` once the last ordinary window closes, so a menu-bar-only session keeps no Dock icon. `INFOPLIST_KEY_LSUIElement` is `NO` accordingly. Anything that assumes "menu bar only" — including where the app icon is visible — is reading a policy the app left behind.
- `AppDelegate` is the composition root: it owns the singleton `AppCoordinator` (constructed with `PluginRegistry.nativeFirst()`), the `MenuBarController` (the status item and its menu — the popover it used to host is gone), and the `GlobalShortcutManager` (Carbon hotkeys for show-window, focus-panel and quick-add).
- **MCP launch mode**: `TaktEntryPoint.main()` in `MainApp.swift` checks for `--mcp-server` and hands the process to `MCPServerShim.run()`, which `execv`s the bundled CLI. This runs *before* `MainApp.main()`, so a process that only speaks JSON-RPC on stdio never initialises AppKit. Preserve that ordering when refactoring startup. See `docs/mcp-server.md`. Straight after that check, and before anything reads preferences or Application Support, `LegacyNameMigration.runIfNeeded()` (`Takt/LegacyNameMigration.swift`) copies — never moves — whatever the old `Application Support/Priority` (and `Bar Tasker`) folder holds that `Takt/` lacks, and the old preferences domain's keys; the MCP server skips it because the CLI falls back to the old locations itself.
- `AppCoordinator` is a known "god object" — it forwards many properties to `TaskRepository`, `NavigationState`, and `TaskListViewModel`, and its responsibilities are split across `AppCoordinator+*.swift` extensions (Navigation, QuickAdd, ReorderingAndTiming, StateAndLifecycle, TaskMutations, TaskScoping, TaskSync, Undo). `ARCHITECTURE_IMPROVEMENT_PLAN.md` describes the intended decomposition; align new work with it rather than entrenching the forwarding pattern.
- `TaskRepository` is the source of truth for tasks/auth/lists. Cache invalidation fans out through `CacheInvalidationBus`: a cache-relevant `var`'s `didSet` calls `bus.invalidate()`, and the single subscriber marks `TaskListViewModel`'s cache dirty. The rebuild is lazy — it happens on the next read of `TaskListViewModel.cache`. Adding cache-relevant state means adding a `bus.invalidate()` to its `didSet`, or the UI goes stale. See `docs/state-ownership.md`.

## Plugin Architecture

All external integrations (Checkvist sync, Obsidian, AFFiNE, Google Calendar, MCP) are plugins behind protocols in `Takt/Plugins/Protocols/PluginProtocols.swift`. Native implementations live one folder per plugin under `Takt/Plugins/Native/<Name>/`, registered through `PluginRegistry` (`PluginRegistry.nativeFirst()` is the production factory).

Conventions enforced by `docs/plugins.md`:

- One folder per plugin; do **not** put plugin-specific services or models at the app root.
- Plugin settings UI lives in a plugin-local `<PluginName>+Settings.swift` extension that conforms to `PluginSettingsPageProviding`. `SettingsView` enumerates active plugins generically — never add `switch`/`if`-by-plugin logic there.
- New plugin files that the SPM `TaktPlugins` target needs must be added to the explicit `sources:` list in `Package.swift`; UI/`+Settings.swift` files stay app-only and should be left out (or excluded).

`NativeDailyLogPlugin` is the one deliberate exception to "contracts live in `Protocols/PluginProtocols.swift`, implementations compile into `TaktPlugins`". Its contract sits in its own file (`Protocols/DailyLogPluginProtocol.swift`) and the whole `Native/DailyLog/` folder is excluded from the `TaktPlugins` target, because it depends on `TaktCore` types (`DayLogEvent`, `DayBoundary`, `DayLogAggregator`) — the same one-file-one-target constraint that keeps `MCPClientInstaller.swift` app-only (it depends on `TaktCore` types too, which `TaktPlugins` can now import — so this exclusion is worth revisiting). Its testable logic lives in `Sources/TaktCore/` instead. Recording reaches it through `TaskMutationHost.recordDayLogTaskAction` (primitives only, since `TaktAppLogic` can't see the event type either) and `FocusSessionManager.onFocusSessionCompleted`. See `docs/plugins.md`.

`OfflineTaskSyncPlugin` provides offline storage. `TaskRepository.activeSyncPlugin` resolves to either it or the Checkvist sync plugin based on `repository.canSyncRemotely`, so callers should always go through `repository.activeSyncPlugin` rather than naming the offline plugin directly.

## Conventions and Tooling

- SwiftLint config (`.swiftlint.yml`) is intentionally permissive: many style-only rules disabled, `file_length` warning at 800 / error at 1500, `function_body_length` warning at 150, `cyclomatic_complexity` warning at 25. Don't gratuitously split files just to satisfy stricter defaults. CI runs `swiftlint lint` (not `--strict`), so **warnings are advisory and errors block**; the standing backlog is a handful of length and complexity warnings on the large files, counted in `TODO.md` rather than suppressed. Don't add to it. Run it as `swiftlint lint` from the root; it is a `--quiet` run of `Takt` and `Sources` that matters, and the config excludes `.claude` and the iOS build folder, which otherwise crash SourceKit.
- Logging uses `os.Logger` with subsystem `uk.co.maybeitssoftware.takt`; reuse this subsystem with a category that matches the type. `AppIdentity.bundleIdentifier` in `Sources/TaktCore/AppIdentity.swift` holds it, alongside `AppIdentity.applicationSupportDirectory()`, which every Application Support path should go through rather than spelling out `Takt/`. Keychain service names deliberately keep the old `uk.co.maybeitsadam.priority` prefix: they are storage keys, not identity.

## Verifying Changes

After any plugin or core-logic change, run both:

```bash
xcodebuild -project 'Takt.xcodeproj' -scheme 'Takt' -configuration Debug -destination 'platform=macOS' build
swift test
swiftlint lint          # `brew install swiftlint`; errors block, warnings don't
```

Xcode catches app-only breakage; `swift test` catches breakage in `TaktCore`/`TaktPlugins`/`TaktAppLogic` (including `Package.swift` source-list drift).

After changing anything under `cli/`, also run:

```bash
cargo test --manifest-path cli/Cargo.toml
cargo clippy --manifest-path cli/Cargo.toml --all-targets -- -D warnings
cargo fmt --manifest-path cli/Cargo.toml --check
```

After changing the MCP server (`cli/src/`) or the handover (`Takt/MCPServerShim.swift`, `scripts/bundle_cli.sh`), also run:

```bash
python3 scripts/mcp_smoke_check.py
```

There used to be two implementations of the same MCP server — one in Swift inside the app, one in the CLI — held equal from the outside by `scripts/mcp_parity_check.py`, because neither could import the other. The Swift one is gone: the app bundles the CLI and `--mcp-server` execs it, so there is one implementation to be right instead of two to keep equal. `cargo test` covers the server; the smoke check covers the seam, and specifically that a client configuration written before that change — naming the app's executable with `--mcp-server` and credentials in `env` — still reaches a working server. It checks `Takt --mcp-server`; a configuration naming the pre-rename `Priority.app` works only while that bundle exists, and the app's MCP setup replaces such an entry with a `takt` one. Needs a Debug app build; reads no real data and needs no credentials.

### Phones and sync

The iPhone app (`mobile/ios`, XcodeGen) and the Android app (`mobile/android`, Gradle) share the workspace with the Mac through `sync-server/` (Railway). The protocol is `docs/sync.md`. The theme format and its per-platform rules are in `docs/themes.md`. The shared fixtures they're held to are `cli/src/fixtures/workspace_schema.sql` and `shared/themes/`.

- **`WorkspaceStore` schema changes** have to reach every client. Add the Android step in `mobile/android/data/.../WorkspaceSchema.kt` with the same SQL, reinstall the sync triggers if a synced table changed, and regenerate the fixture (`scripts/dump_workspace_schema.sh`). Both Android's schema test and the CLI's tests check against it.
- **Theme format changes** go into `Sources/TaktCore/Theming` first. Rerun `TAKT_REGENERATE_THEMES=1 swift test --filter ThemeConformance` and commit the regenerated `shared/themes`. The Kotlin port must still pass every conformance case.

After changing anything under `mobile/ios`:

```bash
(cd mobile/ios && xcodegen generate)
xcodebuild -project mobile/ios/TaktMobile.xcodeproj -scheme TaktMobile -destination 'generic/platform=iOS Simulator' build-for-testing
./scripts/install_ios.sh            # Release build onto the booted simulator, or DEVICE_ID=<udid>
```

After changing anything under `mobile/android` (Gradle builds share `/tmp/priority-gradle.lock`):

```bash
(cd mobile/android && ./gradlew :core:test :data:testDebugUnitTest :app:testDebugUnitTest lint :app:assembleDebug :app:assembleRelease)
./scripts/install_android.sh        # onto the connected device or emulator
./scripts/build_play_bundle.sh      # signed .aab for the Play Console, into build/play/
```

After changing `sync-server/`:

```bash
cargo test --manifest-path sync-server/Cargo.toml   # integration tests need a local Postgres; see sync-server/README.md
cargo clippy --manifest-path sync-server/Cargo.toml --all-targets -- -D warnings
cargo fmt --manifest-path sync-server/Cargo.toml --check
```

## Working Loop

Three things happen on every piece of work here without being asked for.

**Commit as you go, straight onto `main`.** Not one commit at the end — one per
coherent change, each of them green. This is a deliberate override of the
global "commit only when asked; branch first on the default branch" rule:
`main` is the working branch in this repo. Match the existing subject style —
conventional prefix, lowercase, a sentence saying what changed, no trailing
period; `git log` is the reference. A change whose gates don't pass isn't a
commit, so run *Verifying Changes* above first, plus the Rust and MCP gates
when they apply.

Where the work splits into several commits, order them so each one's tree
builds on its own — a history you can't bisect is a history you can only read.
`git worktree add` on a candidate commit checks that without disturbing the
working tree.

**Reinstall the app, every time, yourself.**

```bash
./scripts/install_local.sh
```

This is already the standing instruction in `AGENTS.md`, repeated here because
that file is not always loaded. It builds Release, backs up the existing
`/Applications/Takt.app`, replaces it and relaunches (an old
`/Applications/Priority.app` is moved into `build/backup.noindex/`) — and it is part of
finishing the work, not a step to hand back. A passing `xcodebuild` is not
completion: what the user actually runs is the installed bundle, and until it
is replaced every fix is still only a claim. Check the output for
`** BUILD SUCCEEDED **` and for the `Installed.` line, and report a failure
rather than a summary. The workflow is authorised; do not ask first.

**Reinstall after anything under `cli/`.**

```bash
./scripts/install_cli.sh
```

The installed command is a *symlink* at `~/.local/bin/takt` pointing into
`cli/target/release/`, so what actually matters is that a **release** build is
current — the symlink then updates for free. Two consequences:

- `cargo build` (debug) refreshes neither the installed command nor the helper
  the app ships: `scripts/bundle_cli.sh` copies the *release* binary into
  `Contents/Helpers/takt`. A debug-only build leaves both stale while every
  test still passes, which is exactly how a stale MCP server goes unnoticed.
- `rm -rf cli/target` breaks the installed command rather than leaving an old
  copy behind.

A new entry in `cli/src/tools.rs` needs a front end on **each** side that can
express it — a `Command` case and `resolve` arm in `cli.rs` as well as the
declaration in `mcp.rs` — because the point of the shared tool table is that a
terminal can reach anything an assistant can. It also needs
`EXPECTED_TOOL_COUNT` in `scripts/mcp_smoke_check.py` and the count in
`docs/mcp-server.md` updating; the smoke check fails on the number, which is
the intended reminder.
