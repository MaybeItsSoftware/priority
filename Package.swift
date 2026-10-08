// swift-tools-version: 6.0
import PackageDescription

let pluginTargetExcludes = [
  // Top-level non-source artefacts
  "ARCHITECTURE_IMPROVEMENT_PLAN.md",
  "Takt.xcodeproj",
  "CLAUDE.md",
  // The Rust CLI crate. No Swift sources, but `path: "."` would otherwise walk
  // all of `cli/target` on every build.
  "cli",
  // The Rust core; its Swift face is the TaktRustCore target.
  "core",
  "README.md",
  "applogic-support",
  "applogic-tests",
  "build",
  "corelogic-tests",
  "docs",
  "plugin-tests",
  "workspace-tests",
  "workspace-editing-tests",
  "Takt/Editing",
  "Sources/TaktWorkspace",
  "Sources/TaktSync",
  "sync-tests",
  // The sync server and the phone apps: other build systems, and their build
  // trees are large enough that walking them slows every build.
  "sync-server",
  "mobile",
  "scripts",

  // App resources and the core target's own source tree
  "Takt/Assets.xcassets",
  "Takt/Fonts",
  "Takt/Takt.entitlements",
  "Takt/Takt.release.entitlements",
  "Takt/Info.plist",
  "Takt/WorkspaceDesktopView.swift",
  "Takt/WorkspaceViewModel.swift",

  // App-level source folders not needed by the plugins library
  "Takt/Managers",
  "Takt/Models",

  // App-level source files at Takt/ root
  "Takt/AppCoordinator.swift",
  "Takt/AppDelegate.swift",
  "Takt/CacheInvalidationBus.swift",
  "Takt/CacheState.swift",
  "Takt/CommandExecutor.swift",
  "Takt/DailyLogDataSourceAdapter.swift",
  "Takt/IntegrationDataSourceAdapter.swift",
  "Takt/KanbanTaskDataSourceAdapter.swift",
  "Takt/LifecycleController.swift",
  "Takt/ListScopedPriorityStore.swift",
  "Takt/ListScopedEisenhowerStore.swift",
  "Takt/ListScopedTaskIDStore.swift",
  "Takt/MainApp.swift",
  "Takt/NetworkReachabilityMonitor.swift",
  "Takt/OnboardingService.swift",
  "Takt/DiagnosticsLog.swift",
  "Takt/DiagnosticsView.swift",
  "Takt/MainWindowController.swift",
  "Takt/MainWindowToolbar.swift",
  "Takt/WindowContentSizing.swift",
  // The SwiftUI projection of a `TaktCore` theme. SwiftUI, so app-only.
  "Takt/Theme.swift",
  // App-only: reads UserDefaults and Application Support directly at startup.
  "Takt/LegacyNameMigration.swift",
  "Takt/PreferencesStore.swift",
  "Takt/OptimisticTaskID.swift",
  "Takt/RecurrenceRule.swift",
  "Takt/ReorderQueue.swift",
  "Takt/SettingsNavState.swift",
  "Takt/SettingsView.swift",
  "Takt/SettingsChrome.swift",
  "Takt/CelebrationPreview.swift",
  "Takt/TaskDeletionPrompt.swift",
  "Takt/WorkspaceTaskDraftRow.swift",
  "Takt/SettingsFontPicker.swift",
  "Takt/SettingsView+AdvancedPane.swift",
  "Takt/SettingsView+AppearancePane.swift",
  "Takt/SettingsView+GeneralPane.swift",
  "Takt/SettingsView+KeyboardPane.swift",
  "Takt/AppCoordinator+ServiceHosts.swift",
  "Takt/SyncService.swift",
  "Takt/TaskMutationService.swift",
  "Takt/TaskMutationService+Board.swift",
  // The one place `CheckvistTask` meets `TaktCore`'s `VisibilityTask`. It is
  // a `TaktAppLogic` source, and a file can only belong to one SPM target.
  "Takt/CheckvistTask+VisibilityTask.swift",
  "Takt/TaskServiceHosts.swift",
  "Takt/TaskNavigationCoordinator.swift",
  "Takt/TaskOutlineBuilder.swift",
  "Takt/TaskTreeFormatter.swift",
  "Takt/TaskNavigationService.swift",
  "Takt/UndoService.swift",

  // Plugin subtrees / files that are app-only or conflict with PluginModelStubs
  "Takt/Plugins/Registry",
  // The offline store and its sync plugin are `TaktAppLogic` sources.
  "Takt/Plugins/Native/Offline",
  "Takt/Plugins/Native/Checkvist/CheckvistAPIClient.swift",
  "Takt/Plugins/Native/Checkvist/CheckvistConnectionState.swift",
  "Takt/Plugins/Native/Checkvist/CheckvistSession.swift",
  "Takt/Plugins/Native/Checkvist/CheckvistTaskRepository.swift",
  "Takt/Plugins/Native/Checkvist/NativeCheckvistSyncPlugin+Settings.swift",
  "Takt/Plugins/Native/Google/GoogleOAuthLoopbackReceiver.swift",
  "Takt/Plugins/Native/Google/GoogleAccountSettingsSection.swift",
  "Takt/Plugins/Native/GoogleCalendar/NativeGoogleCalendarIntegrationPlugin+Settings.swift",
  "Takt/Plugins/Native/GoogleCalendar/GoogleCalendarCompletionWatcher.swift",
  "Takt/Plugins/Native/GoogleTasks/NativeGoogleTasksIntegrationPlugin+Settings.swift",
  // App-only: the mirror drives the workspace store, which lives in a module
  // `TaktPlugins` does not depend on.
  "Takt/Plugins/Native/GoogleTasks/GoogleTasksMirrorService.swift",
  "Takt/Plugins/Native/GoogleTasks/GoogleTasksMirrorStores.swift",
  // App-only: drives NSOpenPanel (AppKit). It also depends on `TaktCore`'s
  // catalog, which this target *can* now import, so the exclusion is worth
  // revisiting once the NSOpenPanel dependency is hoisted out.
  "Takt/Plugins/Native/MCP/MCPClientInstaller.swift",
  "Takt/Plugins/Native/MCP/NativeMCPIntegrationPlugin+Settings.swift",
  "Takt/Plugins/Native/AFFiNE/NativeAFFiNEIntegrationPlugin+Settings.swift",
  "Takt/Plugins/Native/Obsidian/NativeObsidianIntegrationPlugin+Settings.swift",
  "Takt/Plugins/Native/Obsidian/ObsidianSyncService.swift",
  "Takt/Plugins/Protocols/PluginSettingsPageProviding.swift",
  // App-only: the daily-log plugin traffics in `TaktCore` types (`DayLogEvent`,
  // `DayBoundary`, `DayLogAggregator`). This target can import `TaktCore`
  // now, so the exclusion is historical and worth revisiting; the logic worth
  // testing lives in `Sources/TaktCore/` and is covered by `corelogic-tests`.
  "Takt/Plugins/Native/DailyLog",
  "Takt/Plugins/Protocols/DailyLogPluginProtocol.swift",
  // App-only: completion celebrations are motion, motion is SwiftUI, and
  // SwiftUI can't be in this target. The decision logic they render lives in
  // `Sources/TaktCore/CompletionMilestonePolicy.swift` and is covered by
  // `corelogic-tests`.
  "Takt/Plugins/Native/Celebration",
  "Takt/Plugins/Protocols/CompletionCelebrationPluginProtocol.swift",
  // App-only for the DailyLog reason exactly: a theme traffics in `TaktCore`
  // types (`ThemePalette`, `ThemeStructure`); the import would resolve now,
  // so this too is worth revisiting. The palette arithmetic worth testing is
  // already in `Sources/TaktCore/Theming/` under `corelogic-tests`.
  "Takt/Plugins/Native/Theme",
  "Takt/Plugins/Protocols/ThemePluginProtocol.swift",
]

// Anything that is *not* an AppLogic source. Mirrors `pluginTargetExcludes` but
// keeps `Takt/Managers/TaskRepository.swift`, the priority/queue stores,
// `Takt/Plugins/Native/Offline/`, etc. unblocked so SPM can pick them up.
let appLogicTargetExcludes = [
  "workspace-editing-tests",
  "Takt/Editing",
  // Top-level non-source artefacts (same set as pluginTargetExcludes; this
  // isn't shared because exclude entries are path-based and we'd risk drift).
  "ARCHITECTURE_IMPROVEMENT_PLAN.md",
  "Takt.xcodeproj",
  "CLAUDE.md",
  // The Rust CLI crate. No Swift sources, but `path: "."` would otherwise walk
  // all of `cli/target` on every build.
  "cli",
  // The Rust core; its Swift face is the TaktRustCore target.
  "core",
  "README.md",
  "applogic-tests",
  "build",
  "corelogic-tests",
  "docs",
  "plugin-tests",
  "plugin-tests-support",
  "workspace-tests",
  "Sources/TaktWorkspace",
  "Sources/TaktSync",
  "sync-tests",
  // The sync server and the phone apps: other build systems, and their build
  // trees are large enough that walking them slows every build.
  "sync-server",
  "mobile",
  "scripts",

  // App resources and other targets' source trees.
  "Takt/Assets.xcassets",
  "Takt/Fonts",
  "Takt/Takt.entitlements",
  "Takt/Takt.release.entitlements",
  "Takt/Info.plist",
  "Takt/WorkspaceDesktopView.swift",
  "Takt/WorkspaceViewModel.swift",

  // Takt/Managers — AppLogic only wants TaskRepository.swift and
  // TaskListViewModel.swift from here; the rest of the directory stays
  // app-only and is excluded file-by-file.
  "Takt/Managers/CompletionCelebrationManager.swift",
  "Takt/Managers/DailyLogManager.swift",
  "Takt/Managers/FocusSessionManager.swift",
  "Takt/Managers/GlobalShortcutManager.swift",
  "Takt/Managers/IntegrationCoordinator.swift",
  "Takt/Managers/IntegrationCoordinator+AFFiNE.swift",
  "Takt/Managers/KanbanManager.swift",
  "Takt/Managers/MenuBarController.swift",
  "Takt/Managers/NavigationState.swift",
  "Takt/Managers/PopoverChromeManager.swift",
  "Takt/Managers/PreferencesManager.swift",
  "Takt/Managers/QuickEntryManager.swift",
  "Takt/Managers/RecurrenceManager.swift",
  "Takt/Managers/StartDateManager.swift",
  "Takt/Managers/ThemeManager.swift",
  "Takt/Managers/TimerManager.swift",

  // Models — AppLogic only wants UndoableAction.swift; the rest are app-only
  // enums. (`CheckvistConnectionState` lives with the Checkvist plugin now.)
  "Takt/Models/AppearanceMode.swift",
  "Takt/Models/CommandSuggestion.swift",
  "Takt/Models/DailyChartRange.swift",
  "Takt/Models/FocusRunSurface.swift",
  "Takt/Models/QuickEntryMode.swift",

  // App-level source files at Takt/ root that AppLogic does not need.
  "Takt/AppCoordinator.swift",
  "Takt/AppCoordinator+ServiceHosts.swift",
  "Takt/AppDelegate.swift",
  "Takt/CommandExecutor.swift",
  "Takt/DailyLogDataSourceAdapter.swift",
  "Takt/IntegrationDataSourceAdapter.swift",
  "Takt/KanbanTaskDataSourceAdapter.swift",
  "Takt/LifecycleController.swift",
  "Takt/MainApp.swift",
  "Takt/NetworkReachabilityMonitor.swift",
  "Takt/OnboardingService.swift",
  "Takt/DiagnosticsLog.swift",
  "Takt/DiagnosticsView.swift",
  "Takt/MainWindowController.swift",
  "Takt/MainWindowToolbar.swift",
  "Takt/WindowContentSizing.swift",
  // App-only: reads UserDefaults and Application Support directly at startup.
  "Takt/LegacyNameMigration.swift",
  "Takt/RecurrenceRule.swift",
  "Takt/SettingsNavState.swift",
  "Takt/SettingsView.swift",
  "Takt/SettingsChrome.swift",
  "Takt/CelebrationPreview.swift",
  "Takt/TaskDeletionPrompt.swift",
  "Takt/WorkspaceTaskDraftRow.swift",
  "Takt/SettingsFontPicker.swift",
  "Takt/SettingsView+AdvancedPane.swift",
  "Takt/SettingsView+AppearancePane.swift",
  "Takt/SettingsView+GeneralPane.swift",
  "Takt/SettingsView+KeyboardPane.swift",
  "Takt/TaskNavigationService.swift",
  "Takt/TaskTreeFormatter.swift",
  "Takt/Theme.swift",

  // Plugin subtrees (AppLogic pulls `Native/Offline/` and
  // `Checkvist/CheckvistConnectionState.swift` as sources; everything else is
  // app-only or lives in TaktPlugins). The Checkvist folder is excluded file
  // by file for that reason — a folder cannot be both excluded and the home
  // of a source.
  "Takt/Plugins/Registry",
  "Takt/Plugins/Support",
  "Takt/Plugins/Protocols/PluginProtocols.swift",
  "Takt/Plugins/Protocols/PluginSettingsPageProviding.swift",
  "Takt/Plugins/Protocols/DailyLogPluginProtocol.swift",
  "Takt/Plugins/Protocols/CompletionCelebrationPluginProtocol.swift",
  "Takt/Plugins/Protocols/ThemePluginProtocol.swift",
  "Takt/Plugins/Native/AFFiNE",
  "Takt/Plugins/Native/Celebration",
  "Takt/Plugins/Native/Checkvist/CheckvistAPIClient.swift",
  "Takt/Plugins/Native/Checkvist/CheckvistCredentialStore.swift",
  "Takt/Plugins/Native/Checkvist/CheckvistEndpoints.swift",
  "Takt/Plugins/Native/Checkvist/CheckvistModels.swift",
  "Takt/Plugins/Native/Checkvist/CheckvistSession.swift",
  "Takt/Plugins/Native/Checkvist/CheckvistSessionError.swift",
  "Takt/Plugins/Native/Checkvist/CheckvistTaskCachePayload.swift",
  "Takt/Plugins/Native/Checkvist/CheckvistTaskRepository.swift",
  "Takt/Plugins/Native/Checkvist/NativeCheckvistSyncPlugin.swift",
  "Takt/Plugins/Native/Checkvist/NativeCheckvistSyncPlugin+Settings.swift",
  "Takt/Plugins/Native/DailyLog",
  "Takt/Plugins/Native/Google",
  "Takt/Plugins/Native/GoogleCalendar",
  "Takt/Plugins/Native/GoogleTasks",
  "Takt/Plugins/Native/MCP",
  "Takt/Plugins/Native/Obsidian",
  "Takt/Plugins/Native/Theme",
  "Takt/Plugins/User",
]

let package = Package(
  name: "priority-core",
  // iOS is for the phone app in `mobile/ios`, which links the workspace
  // packages rather than re-implementing them. The plugin and app-logic targets
  // are only ever built for the Mac.
  platforms: [.macOS(.v15), .iOS(.v18)],
  products: [
    .library(name: "TaktCore", targets: ["TaktCore"]),
    .library(name: "TaktPlugins", targets: ["TaktPlugins"]),
    .library(name: "TaktAppLogic", targets: ["TaktAppLogic"]),
    .library(name: "TaktWorkspace", targets: ["TaktWorkspace"]),
    .library(name: "TaktWorkspaceEditing", targets: ["TaktWorkspaceEditing"]),
    .library(name: "TaktSync", targets: ["TaktSync"]),
    .library(name: "TaktRustCore", targets: ["TaktRustCore"]),
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.8.0"),
    // Supabase Auth: accounts for sync (`docs/sync.md`). Only the `Auth`
    // product is linked, by `TaktSync`.
    .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.55.0"),
  ],
  targets: [
    .target(
      name: "TaktCore",
      // The next-up ranking and the availability rules are the Rust core's.
      dependencies: ["TaktRustCore"],
      path: "Sources/TaktCore"
    ),
    // The Rust core (`core/`), compiled for every Apple slice by
    // `scripts/build_core_apple.sh`. The xcframework is a build product, not
    // committed, so the package resolves only once that script has run.
    // `docs/rust-core-migration.md` is the plan for what moves into it.
    .binaryTarget(
      name: "takt_coreFFI",
      path: "build/core/takt_coreFFI.xcframework"
    ),
    // The UniFFI bindings over it, regenerated by the same script and
    // committed so a diff shows when the boundary changed.
    .target(
      name: "TaktRustCore",
      dependencies: ["takt_coreFFI"],
      path: "Sources/TaktRustCore",
      // The core links the system SQLite on Apple platforms, the library GRDB
      // uses too; say so here, so a product that takes the core without GRDB
      // still links it.
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .target(
      name: "TaktWorkspace",
      dependencies: [
        "TaktCore",
        // The schema and its migrations live in the Rust core.
        "TaktRustCore",
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      path: "Sources/TaktWorkspace"
    ),
    // The client half of multi-device sync (`docs/sync.md`), shared by the Mac
    // and iOS apps. Android has its own in `mobile/android/data`.
    .target(
      name: "TaktSync",
      dependencies: [
        "TaktWorkspace",
        .product(name: "Auth", package: "supabase-swift"),
      ],
      path: "Sources/TaktSync"
    ),
    .target(
      name: "TaktPlugins",
      // Same unlock as `TaktAppLogic`: these sources compile into the Xcode
      // app as well, and the app now links `TaktCore` rather than compiling
      // it, so the module resolves on both sides.
      dependencies: ["TaktCore"],
      path: ".",
      exclude: pluginTargetExcludes,
      sources: [
        "Takt/Plugins/Protocols/PluginProtocols.swift",
        "Takt/Plugins/Native/Checkvist/NativeCheckvistSyncPlugin.swift",
        "Takt/Plugins/Native/Checkvist/CheckvistCredentialStore.swift",
        "Takt/Plugins/Native/Checkvist/CheckvistEndpoints.swift",
        "Takt/Plugins/Native/Checkvist/CheckvistModels.swift",
        "Takt/Plugins/Native/Checkvist/CheckvistTaskCachePayload.swift",
        "Takt/Plugins/Native/Checkvist/CheckvistSessionError.swift",
        "Takt/Plugins/Native/AFFiNE/AFFiNEMCPSession.swift",
        "Takt/Plugins/Native/AFFiNE/AFFiNEExportService.swift",
        "Takt/Plugins/Native/AFFiNE/NativeAFFiNEIntegrationPlugin.swift",
        "Takt/Plugins/Native/Obsidian/ObsidianOpenMode.swift",
        "Takt/Plugins/Native/Obsidian/NativeObsidianIntegrationPlugin.swift",
        "Takt/Plugins/Native/Google/GoogleAccount.swift",
        "Takt/Plugins/Native/Google/GoogleOAuthTokenStore.swift",
        "Takt/Plugins/Native/GoogleCalendar/NativeGoogleCalendarIntegrationPlugin.swift",
        "Takt/Plugins/Native/GoogleTasks/NativeGoogleTasksIntegrationPlugin.swift",
        "Takt/Plugins/Native/MCP/NativeMCPIntegrationPlugin.swift",
        "Takt/Plugins/User/UserPluginManager.swift",
        "Takt/Plugins/User/UserPluginManifest.swift",
        "Takt/Plugins/Support/FormURLEncoding.swift",
        "plugin-tests-support/PluginModelStubs.swift",
      ]
    ),
    .target(
      name: "TaktWorkspaceEditing",
      dependencies: ["TaktWorkspace"],
      path: "Takt/Editing"
    ),
    // AppLogic hosts the headless-but-app-bound state machines (TaskRepository,
    // OfflineTaskSyncPlugin, the priority/queue/eisenhower stores, etc.) so they
    // can be exercised by `swift test` without spinning up the Xcode app target.
    // The Checkvist data types and `CheckvistSyncPlugin` protocol are
    // re-declared in `applogic-support/AppLogicSharedTypes.swift` because
    // promoting them out of `TaktPlugins` would require making them
    // `public` — see the Phase 5.2 note in ARCHITECTURE_IMPROVEMENT_PLAN.md.
    .target(
      name: "TaktAppLogic",
      // Legal at last. `TaktAppLogic`'s sources are still compiled into the
      // Xcode app as well as into this target, and an `import TaktCore`
      // line used to break the app build because no such module existed there.
      // Now the app *links* TaktCore rather than compiling its sources, so
      // the module exists on both sides and the import resolves either way.
      dependencies: ["TaktCore"],
      path: ".",
      exclude: appLogicTargetExcludes,
      sources: [
        "Takt/Managers/TaskRepository.swift",
        // Reachable at last: it needs `TaktCore`'s visibility engines, and
        // this target could not import them until the app started linking the
        // package rather than compiling its sources.
        "Takt/Managers/TaskListViewModel.swift",
        "Takt/CacheState.swift",
        // Conforms the Checkvist model to `TaktCore`'s `VisibilityTask`.
        // Compiled into both this target and the app, so each side's
        // declaration of `CheckvistTask` picks up the conformance.
        "Takt/CheckvistTask+VisibilityTask.swift",
        "Takt/CacheInvalidationBus.swift",
        "Takt/UndoService.swift",
        "Takt/Plugins/Native/Offline/LocalTaskStore.swift",
        "Takt/OptimisticTaskID.swift",
        "Takt/ReorderQueue.swift",
        "Takt/SyncService.swift",
        "Takt/TaskMutationService.swift",
        "Takt/TaskMutationService+Board.swift",
        "Takt/TaskServiceHosts.swift",
        "Takt/TaskNavigationCoordinator.swift",
        // The outline flattening `TaskNavigationCoordinator` decides against.
        // Pure, and covered by `TaskOutlineBuilderTests`.
        "Takt/TaskOutlineBuilder.swift",
        "Takt/ListScopedPriorityStore.swift",
        "Takt/ListScopedTaskIDStore.swift",
        "Takt/ListScopedEisenhowerStore.swift",
        "Takt/Plugins/Native/Offline/OfflineTaskSyncPlugin.swift",
        "Takt/PreferencesStore.swift",
        "Takt/Models/UndoableAction.swift",
        "Takt/Plugins/Native/Checkvist/CheckvistConnectionState.swift",
        "applogic-support/AppLogicSharedTypes.swift",
      ]
    ),
    .testTarget(
      name: "TaktCoreTests",
      dependencies: ["TaktCore"],
      path: "corelogic-tests"
    ),
    .testTarget(
      name: "TaktPluginTests",
      dependencies: ["TaktPlugins"],
      path: "plugin-tests"
    ),
    .testTarget(
      name: "TaktAppLogicTests",
      dependencies: ["TaktAppLogic", "TaktPlugins"],
      path: "applogic-tests"
    ),
    .testTarget(
      name: "TaktWorkspaceTests",
      // GRDB directly, so a migration test can write a fixture database in the
      // shape an older version of the app left behind.
      dependencies: ["TaktWorkspace", .product(name: "GRDB", package: "GRDB.swift")],
      path: "workspace-tests"
    ),
    .testTarget(
      name: "TaktRustCoreTests",
      dependencies: ["TaktRustCore"],
      path: "rustcore-tests"
    ),
    .testTarget(
      name: "TaktWorkspaceEditingTests",
      dependencies: ["TaktWorkspaceEditing", "TaktWorkspace"],
      path: "workspace-editing-tests"
    ),
    .testTarget(
      name: "TaktSyncTests",
      dependencies: [
        "TaktSync", "TaktWorkspace", .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "Auth", package: "supabase-swift"),
      ],
      path: "sync-tests"
    ),
  ]
)
