# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Priority is a keyboard-first macOS desktop app (macOS 15.6+, Xcode 17+) with a menu bar surface beside it. Its own local workspace is the source of truth; Checkvist is an optional import/integration edge. `DESKTOP_WORKSPACE_ROADMAP.md` is authoritative for where that transition has got to. It is an Xcode app with a Swift Package layered on top — `Package.swift` exposes `PriorityCore` (pure logic), `PriorityPlugins` (integration plugins), and `PriorityAppLogic` (the headless-but-app-bound state machines) as SPM library targets that share source with the Xcode project.

`cli/` is a separate Rust crate producing `priority`. Bare `priority` opens a ratatui terminal UI whose tabs mirror the app's root views; `cli.rs`, `tui/` and `mcp.rs` are three front ends onto the single tool table in `tools.rs`, so none of them can implement behaviour the others lack. It is a command-line peer of the app that talks to the Checkvist API directly and reads the same local files. It shares no source with the Swift side, and the only thing in `Priority/` that may reference it is `MCPServerShim.swift`: the app bundles the CLI as a signed helper at `Contents/Helpers/priority` (see `scripts/bundle_cli.sh`) and `Priority --mcp-server` `execv`s it. That is the app's MCP server — there is no other. Consequently **an app build needs cargo**; set `PRIORITY_SKIP_CLI_BUNDLE=1` to skip it, at the cost of an app with no MCP server. Its credentials are deliberately its own (`~/.config/priority/config.json`, see `cli/src/config.rs`) rather than the app's keychain item, which is reachable only by something carrying the app's code signature. See `docs/cli.md`.

## Build, Run, Test

```bash
# Full app build (the canonical "does it compile" check)
xcodebuild -project 'Priority.xcodeproj' -scheme 'Priority' -configuration Debug -destination 'platform=macOS' build

# Run all SPM unit tests (PriorityCoreTests + PriorityPluginTests + PriorityAppLogicTests)
swift test

# Run a single test by filter (XCTest style)
swift test --filter PriorityCoreTests.CommandEngineCommandParsingTests/testParseSimpleKeywordCommands

# Build + launch the Debug app (kills any running instance first)
./scripts/run.sh

# Produce a release DMG
./scripts/build_dmg.sh <version>

# The Rust CLI
cargo test --manifest-path cli/Cargo.toml
cargo clippy --manifest-path cli/Cargo.toml --all-targets -- -D warnings
cargo fmt --manifest-path cli/Cargo.toml --check
./scripts/install_cli.sh            # release build + a symlink onto PATH
```

`README.md` is authoritative for keybindings and command palette syntax — consult it when editing `KeyboardShortcutRouter.swift` or `CommandEngine.swift` so behaviour stays in sync.

## Architectural Layout (Two Build Systems, One Source Tree)

The same files are compiled by two different systems, which is the most important thing to know before editing:

1. **Xcode project** (`Priority.xcodeproj`) — builds the actual macOS app from everything under `Priority/`.
2. **Swift Package** (`Package.swift`) — builds three libraries from curated subsets:
   - `PriorityCore` — sources rooted at `Sources/PriorityCore/`. Pure, headless logic only (command parser, recurrence, timer policies, the visibility/kanban/shortcut engines). This is what `corelogic-tests/` exercises. **The app links this one** rather than compiling its sources, so everything it uses across that boundary is `public`.
   - `PriorityPlugins` — explicit `sources:` list of plugin files plus `plugin-tests-support/PluginModelStubs.swift` (which provides minimal stub models so plugin code compiles without the app shell). Tested by `plugin-tests/`.
   - `PriorityAppLogic` — explicit `sources:` list of the app-bound state machines (`TaskRepository`, `TaskMutationService`, `SyncService`, `UndoService`, the offline/priority stores) plus `applogic-support/AppLogicSharedTypes.swift`, which re-declares the Checkvist models rather than making `PriorityPlugins` publish them. Tested by `applogic-tests/`.

Consequences when editing:

- `Package.swift` has a large `pluginTargetExcludes` list and explicit `sources:` lists for the two `path: "."` targets. Adding a new plugin or app-logic file requires updating them, or `swift test` starts failing even though Xcode still builds. `Sources/PriorityCore/` needs no such bookkeeping — it is a real single-target directory, so a new file there is picked up by both builds.
- `PriorityCore` must stay free of AppKit/SwiftUI/UI dependencies — it is consumed by the test target without the app. New declarations there need `public` to be visible to the app, and a `public struct` needs an explicit `public init` (the synthesised memberwise one is internal).
- `PriorityPlugins` deliberately excludes each plugin's `+Settings.swift` extension and any service that pulls in app types (e.g. `CheckvistAPIClient.swift`, `ObsidianSyncService.swift`). Keep cross-plugin / app-only types out of the curated `sources:` list.
- `PriorityAppLogic` sources must not import AppKit or SwiftUI either. `TaskMutationService` and `SyncService` reach the UI layer through the `TaskMutationHost` / `SyncHost` protocols in `Priority/TaskServiceHosts.swift`; `AppCoordinator` provides the production conformance in `AppCoordinator+ServiceHosts.swift`, which is the app-only side and stays out of the package. Adding a coordinator dependency to either service means adding a host member, not a `weak var coordinator`.
- **A file can only belong to one SPM target.** That still holds for `PriorityPlugins` and `PriorityAppLogic`, whose sources are compiled by both build systems. What no longer holds is the consequence this file used to draw from it: both targets *can* now `import PriorityCore`, because the app links that module rather than compiling its sources, so the import resolves on both sides. `OfflineReplayPolicy.swift` moved into `Sources/PriorityCore` accordingly.

## App Composition

- `MainApp.swift` is a near-empty `@main` that installs `AppDelegate` via `NSApplicationDelegateAdaptor`. The activation policy is **not** fixed: `applicationDidFinishLaunching` sets `.regular` because the desktop window is the launch surface, and `applyActivationPolicy(hasOrdinaryWindow:)` drops back to `.accessory` once the last ordinary window closes, so a menu-bar-only session keeps no Dock icon. `INFOPLIST_KEY_LSUIElement` is `NO` accordingly. Anything that assumes "menu bar only" — including where the app icon is visible — is reading a policy the app left behind.
- `AppDelegate` is the composition root: it owns the singleton `AppCoordinator` (constructed with `PluginRegistry.nativeFirst()`), the `MenuBarController` (the status item and its menu — the popover it used to host is gone), and the `GlobalShortcutManager` (Carbon hotkeys for show-window, focus-panel and quick-add).
- **MCP launch mode**: `PriorityEntryPoint.main()` in `MainApp.swift` checks for `--mcp-server` and hands the process to `MCPServerShim.run()`, which `execv`s the bundled CLI. This runs *before* `MainApp.main()`, so a process that only speaks JSON-RPC on stdio never initialises AppKit. Preserve that ordering when refactoring startup. See `docs/mcp-server.md`.
- `AppCoordinator` is a known "god object" — it forwards many properties to `TaskRepository`, `NavigationState`, and `TaskListViewModel`, and its responsibilities are split across `AppCoordinator+*.swift` extensions (Navigation, QuickAdd, ReorderingAndTiming, StateAndLifecycle, TaskMutations, TaskScoping, TaskSync, Undo). `ARCHITECTURE_IMPROVEMENT_PLAN.md` describes the intended decomposition; align new work with it rather than entrenching the forwarding pattern.
- `TaskRepository` is the source of truth for tasks/auth/lists. Cache invalidation fans out through `CacheInvalidationBus`: a cache-relevant `var`'s `didSet` calls `bus.invalidate()`, and the single subscriber marks `TaskListViewModel`'s cache dirty. The rebuild is lazy — it happens on the next read of `TaskListViewModel.cache`. Adding cache-relevant state means adding a `bus.invalidate()` to its `didSet`, or the UI goes stale. See `docs/state-ownership.md`.

## Plugin Architecture

All external integrations (Checkvist sync, Obsidian, AFFiNE, Google Calendar, MCP) are plugins behind protocols in `Priority/Plugins/Protocols/PluginProtocols.swift`. Native implementations live one folder per plugin under `Priority/Plugins/Native/<Name>/`, registered through `PluginRegistry` (`PluginRegistry.nativeFirst()` is the production factory).

Conventions enforced by `docs/plugins.md`:

- One folder per plugin; do **not** put plugin-specific services or models at the app root.
- Plugin settings UI lives in a plugin-local `<PluginName>+Settings.swift` extension that conforms to `PluginSettingsPageProviding`. `SettingsView` enumerates active plugins generically — never add `switch`/`if`-by-plugin logic there.
- New plugin files that the SPM `PriorityPlugins` target needs must be added to the explicit `sources:` list in `Package.swift`; UI/`+Settings.swift` files stay app-only and should be left out (or excluded).

`NativeDailyLogPlugin` is the one deliberate exception to "contracts live in `Protocols/PluginProtocols.swift`, implementations compile into `PriorityPlugins`". Its contract sits in its own file (`Protocols/DailyLogPluginProtocol.swift`) and the whole `Native/DailyLog/` folder is excluded from the `PriorityPlugins` target, because it depends on `PriorityCore` types (`DayLogEvent`, `DayBoundary`, `DayLogAggregator`) — the same one-file-one-target constraint that keeps `MCPClientInstaller.swift` app-only (it depends on `PriorityCore` types too, which `PriorityPlugins` can now import — so this exclusion is worth revisiting). Its testable logic lives in `Sources/PriorityCore/` instead. Recording reaches it through `TaskMutationHost.recordDayLogTaskAction` (primitives only, since `PriorityAppLogic` can't see the event type either) and `FocusSessionManager.onFocusSessionCompleted`. See `docs/plugins.md`.

`OfflineTaskSyncPlugin` provides offline storage. `TaskRepository.activeSyncPlugin` resolves to either it or the Checkvist sync plugin based on `repository.canSyncRemotely`, so callers should always go through `repository.activeSyncPlugin` rather than naming the offline plugin directly.

## Conventions and Tooling

- SwiftLint config (`.swiftlint.yml`) is intentionally permissive: many style-only rules disabled, `file_length` warning at 800 / error at 1500, `function_body_length` warning at 150, `cyclomatic_complexity` warning at 25. Don't gratuitously split files just to satisfy stricter defaults. CI runs `swiftlint lint` (not `--strict`), so **warnings are advisory and errors block**; there is a standing backlog of ~13 warnings on the large files, tracked in `ARCHITECTURE_IMPROVEMENT_PLAN.md` rather than suppressed. Don't add to it.
- `check_braces.py` and `check_indent.py` are throwaway diagnostic scripts hard-coded to `Priority/KanbanBoardView.swift`. Not part of CI; ignore unless debugging that file.
- `FocusCore/` is a separate Swift package (sibling, not consumed by the main package) — leave it alone unless explicitly asked.
- Logging uses `os.Logger` with subsystem `uk.co.maybeitsadam.priority`; reuse this subsystem with a category that matches the type.

## Verifying Changes

After any plugin or core-logic change, run both:

```bash
xcodebuild -project 'Priority.xcodeproj' -scheme 'Priority' -configuration Debug -destination 'platform=macOS' build
swift test
swiftlint lint          # `brew install swiftlint`; errors block, warnings don't
```

Xcode catches app-only breakage; `swift test` catches breakage in `PriorityCore`/`PriorityPlugins`/`PriorityAppLogic` (including `Package.swift` source-list drift).

After changing anything under `cli/`, also run:

```bash
cargo test --manifest-path cli/Cargo.toml
cargo clippy --manifest-path cli/Cargo.toml --all-targets -- -D warnings
cargo fmt --manifest-path cli/Cargo.toml --check
```

After changing the MCP server (`cli/src/`) or the handover (`Priority/MCPServerShim.swift`, `scripts/bundle_cli.sh`), also run:

```bash
python3 scripts/mcp_smoke_check.py
```

There used to be two implementations of the same MCP server — one in Swift inside the app, one in the CLI — held equal from the outside by `scripts/mcp_parity_check.py`, because neither could import the other. The Swift one is gone: the app bundles the CLI and `--mcp-server` execs it, so there is one implementation to be right instead of two to keep equal. `cargo test` covers the server; the smoke check covers the seam, and specifically that a client configuration written before that change — naming `Priority --mcp-server`, with credentials in `env` — still reaches a working server. Needs a Debug app build; reads no real data and needs no credentials.

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
`/Applications/Priority.app`, replaces it and relaunches — and it is part of
finishing the work, not a step to hand back. A passing `xcodebuild` is not
completion: what the user actually runs is the installed bundle, and until it
is replaced every fix is still only a claim. Check the output for
`** BUILD SUCCEEDED **` and for the `Installed.` line, and report a failure
rather than a summary. The workflow is authorised; do not ask first.

**Reinstall after anything under `cli/`.**

```bash
./scripts/install_cli.sh
```

The installed command is a *symlink* at `~/.local/bin/priority` pointing into
`cli/target/release/`, so what actually matters is that a **release** build is
current — the symlink then updates for free. Two consequences:

- `cargo build` (debug) refreshes neither the installed command nor the helper
  the app ships: `scripts/bundle_cli.sh` copies the *release* binary into
  `Contents/Helpers/priority`. A debug-only build leaves both stale while every
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
