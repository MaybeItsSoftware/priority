// swift-tools-version: 6.0
import PackageDescription

let pluginTargetExcludes = [
  // Top-level non-source artefacts
  "ARCHITECTURE_IMPROVEMENT_PLAN.md",
  "Priority.xcodeproj",
  "CLAUDE.md",
  // The Rust CLI crate. No Swift sources, but `path: "."` would otherwise walk
  // all of `cli/target` on every build.
  "cli",
  "README.md",
  "applogic-support",
  "applogic-tests",
  "build",
  "corelogic-tests",
  "docs",
  "plugin-tests",
  "workspace-tests",
  "workspace-editing-tests",
  "Priority/Editing",
  "Sources/PriorityWorkspace",
  "Sources/PrioritySync",
  "sync-tests",
  // The sync server and the phone apps: other build systems, and their build
  // trees are large enough that walking them slows every build.
  "sync-server",
  "mobile",
  "scripts",

  // App resources and the core target's own source tree
  "Priority/Assets.xcassets",
  "Priority/Fonts",
  "Priority/Priority.entitlements",
  "Priority/Priority.release.entitlements",
  "Priority/WorkspaceDesktopView.swift",
  "Priority/WorkspaceViewModel.swift",

  // App-level source folders not needed by the plugins library
  "Priority/Managers",
  "Priority/Models",

  // App-level source files at Priority/ root
  "Priority/AppCoordinator.swift",
  "Priority/AppDelegate.swift",
  "Priority/AppThemeColorSupport.swift",
  "Priority/CacheInvalidationBus.swift",
  "Priority/CacheState.swift",
  "Priority/CommandExecutor.swift",
  "Priority/DailyLogDataSourceAdapter.swift",
  "Priority/IntegrationDataSourceAdapter.swift",
  "Priority/KanbanTaskDataSourceAdapter.swift",
  "Priority/LifecycleController.swift",
  "Priority/ListScopedPriorityStore.swift",
  "Priority/ListScopedEisenhowerStore.swift",
  "Priority/ListScopedTaskIDStore.swift",
  "Priority/LocalTaskStore.swift",
  "Priority/MainApp.swift",
  "Priority/NetworkReachabilityMonitor.swift",
  "Priority/OnboardingService.swift",
  "Priority/DiagnosticsLog.swift",
  "Priority/DiagnosticsView.swift",
  "Priority/MainWindowController.swift",
  "Priority/MainWindowToolbar.swift",
  "Priority/WindowContentSizing.swift",
  // The SwiftUI projection of a `PriorityCore` theme. SwiftUI, so app-only.
  "Priority/Theme.swift",
  // App-only: reads UserDefaults and Application Support directly at startup.
  "Priority/LegacyNameMigration.swift",
  "Priority/PreferencesStore.swift",
  "Priority/OptimisticTaskID.swift",
  "Priority/RecurrenceRule.swift",
  "Priority/ReorderQueue.swift",
  "Priority/SettingsNavState.swift",
  "Priority/SettingsView.swift",
  "Priority/SettingsView+DebugPane.swift",
  "Priority/SettingsView+KeybindingsPane.swift",
  "Priority/SettingsView+PreferencesPane.swift",
  "Priority/SettingsView+ThemePane.swift",
  "Priority/AppCoordinator+ServiceHosts.swift",
  "Priority/SyncService.swift",
  "Priority/TaskMutationService.swift",
  "Priority/TaskMutationService+Board.swift",
  "Priority/CheckvistTask+VisibilityTask.swift",
  "Priority/TaskServiceHosts.swift",
  "Priority/TaskNavigationCoordinator.swift",
  "Priority/TaskOutlineBuilder.swift",
  "Priority/TaskTreeFormatter.swift",
  "Priority/TaskNavigationService.swift",
  "Priority/Typography.swift",
  "Priority/UndoService.swift",

  // Plugin subtrees / files that are app-only or conflict with PluginModelStubs
  "Priority/Plugins/Registry",
  "Priority/Plugins/Native/OfflineTaskSyncPlugin.swift",
  "Priority/Plugins/Native/Checkvist/CheckvistAPIClient.swift",
  "Priority/Plugins/Native/Checkvist/CheckvistSession.swift",
  "Priority/Plugins/Native/Checkvist/CheckvistTaskRepository.swift",
  "Priority/Plugins/Native/Checkvist/NativeCheckvistSyncPlugin+Settings.swift",
  "Priority/Plugins/Native/Google/GoogleOAuthLoopbackReceiver.swift",
  "Priority/Plugins/Native/Google/GoogleAccountSettingsSection.swift",
  "Priority/Plugins/Native/GoogleCalendar/NativeGoogleCalendarIntegrationPlugin+Settings.swift",
  "Priority/Plugins/Native/GoogleCalendar/GoogleCalendarCompletionWatcher.swift",
  "Priority/Plugins/Native/GoogleTasks/NativeGoogleTasksIntegrationPlugin+Settings.swift",
  // App-only: the mirror drives the workspace store, which lives in a module
  // `PriorityPlugins` does not depend on.
  "Priority/Plugins/Native/GoogleTasks/GoogleTasksMirrorService.swift",
  "Priority/Plugins/Native/GoogleTasks/GoogleTasksMirrorStores.swift",
  // App-only: drives NSOpenPanel and depends on `PriorityCore`'s catalog,
  // which `PriorityPlugins` can't import (one file, one target).
  "Priority/Plugins/Native/MCP/MCPClientInstaller.swift",
  "Priority/Plugins/Native/MCP/NativeMCPIntegrationPlugin+Settings.swift",
  "Priority/Plugins/Native/AFFiNE/NativeAFFiNEIntegrationPlugin+Settings.swift",
  "Priority/Plugins/Native/Obsidian/NativeObsidianIntegrationPlugin+Settings.swift",
  "Priority/Plugins/Native/Obsidian/ObsidianSyncService.swift",
  "Priority/Plugins/Protocols/PluginSettingsPageProviding.swift",
  // App-only for the same reason as `MCPClientInstaller.swift`: the daily-log
  // plugin traffics in `PriorityCore` types (`DayLogEvent`, `DayBoundary`,
  // `DayLogAggregator`), and one file can't belong to two SPM targets, so
  // `PriorityPlugins` can't import the module that defines them. The logic
  // worth testing lives in `CoreLogic/` and is covered by `corelogic-tests`.
  "Priority/Plugins/Native/DailyLog",
  "Priority/Plugins/Protocols/DailyLogPluginProtocol.swift",
  // App-only for a third variant of the same reason: completion celebrations
  // are motion, motion is SwiftUI, and SwiftUI can't be in this target. The
  // decision logic they render lives in `CoreLogic/CompletionMilestonePolicy`
  // and is covered by `corelogic-tests`.
  "Priority/Plugins/Native/Celebration",
  "Priority/Plugins/Protocols/CompletionCelebrationPluginProtocol.swift",
  // App-only for the DailyLog reason exactly: a theme traffics in
  // `PriorityCore` types (`ThemePalette`, `ThemeStructure`), one file can't
  // belong to two SPM targets, and the palette arithmetic worth testing is
  // already in `Sources/PriorityCore/Theming/` under `corelogic-tests`.
  "Priority/Plugins/Native/Theme",
  "Priority/Plugins/Protocols/ThemePluginProtocol.swift",
]

// Anything that is *not* an AppLogic source. Mirrors `pluginTargetExcludes` but
// keeps `Priority/Managers/TaskRepository.swift`, the priority/queue stores,
// `OfflineTaskSyncPlugin.swift`, etc. unblocked so SPM can pick them up.
let appLogicTargetExcludes = [
  "workspace-editing-tests",
  "Priority/Editing",
  // Top-level non-source artefacts (same set as pluginTargetExcludes; this
  // isn't shared because exclude entries are path-based and we'd risk drift).
  "ARCHITECTURE_IMPROVEMENT_PLAN.md",
  "Priority.xcodeproj",
  "CLAUDE.md",
  // The Rust CLI crate. No Swift sources, but `path: "."` would otherwise walk
  // all of `cli/target` on every build.
  "cli",
  "README.md",
  "applogic-tests",
  "build",
  "corelogic-tests",
  "docs",
  "plugin-tests",
  "plugin-tests-support",
  "workspace-tests",
  "Sources/PriorityWorkspace",
  "Sources/PrioritySync",
  "sync-tests",
  // The sync server and the phone apps: other build systems, and their build
  // trees are large enough that walking them slows every build.
  "sync-server",
  "mobile",
  "scripts",

  // App resources and other targets' source trees.
  "Priority/Assets.xcassets",
  "Priority/Fonts",
  "Priority/Priority.entitlements",
  "Priority/Priority.release.entitlements",
  "Priority/WorkspaceDesktopView.swift",
  "Priority/WorkspaceViewModel.swift",

  // Priority/Managers — AppLogic only wants TaskRepository.swift from here;
  // the rest of the directory pulls in AppKit/SwiftUI and is excluded file-by-file.
  "Priority/Managers/CompletionCelebrationManager.swift",
  "Priority/Managers/DailyLogManager.swift",
  "Priority/Managers/FocusSessionManager.swift",
  "Priority/Managers/GlobalShortcutManager.swift",
  "Priority/Managers/IntegrationCoordinator.swift",
  "Priority/Managers/IntegrationCoordinator+AFFiNE.swift",
  "Priority/Managers/KanbanManager.swift",
  "Priority/Managers/MenuBarController.swift",
  "Priority/Managers/NavigationState.swift",
  "Priority/Managers/PopoverChromeManager.swift",
  "Priority/Managers/PreferencesManager.swift",
  "Priority/Managers/QuickEntryManager.swift",
  "Priority/Managers/RecurrenceManager.swift",
  "Priority/Managers/StartDateManager.swift",
  "Priority/Managers/ThemeManager.swift",
  "Priority/Managers/TimerManager.swift",

  // Models — AppLogic only wants UndoableAction.swift and CheckvistConnectionState.swift;
  // the rest are app-only enums.
  "Priority/Models/AppThemeModels.swift",
  "Priority/Models/CommandSuggestion.swift",
  "Priority/Models/DailyChartRange.swift",
  "Priority/Models/QuickAddLocationMode.swift",
  "Priority/Models/QuickEntryMode.swift",

  // App-level source files at Priority/ root that AppLogic does not need.
  "Priority/AppCoordinator.swift",
  "Priority/AppCoordinator+ServiceHosts.swift",
  "Priority/AppDelegate.swift",
  "Priority/AppThemeColorSupport.swift",
  "Priority/CommandExecutor.swift",
  "Priority/DailyLogDataSourceAdapter.swift",
  "Priority/IntegrationDataSourceAdapter.swift",
  "Priority/KanbanTaskDataSourceAdapter.swift",
  "Priority/LifecycleController.swift",
  "Priority/MainApp.swift",
  "Priority/NetworkReachabilityMonitor.swift",
  "Priority/OnboardingService.swift",
  "Priority/DiagnosticsLog.swift",
  "Priority/DiagnosticsView.swift",
  "Priority/MainWindowController.swift",
  "Priority/MainWindowToolbar.swift",
  "Priority/WindowContentSizing.swift",
  // The one place `CheckvistTask` meets `PriorityCore`'s `VisibilityTask`.
  // App-only by construction: neither library may see both halves.
  // App-only: reads UserDefaults and Application Support directly at startup.
  "Priority/LegacyNameMigration.swift",
  "Priority/RecurrenceRule.swift",
  "Priority/SettingsNavState.swift",
  "Priority/SettingsView.swift",
  "Priority/SettingsView+DebugPane.swift",
  "Priority/SettingsView+KeybindingsPane.swift",
  "Priority/SettingsView+PreferencesPane.swift",
  "Priority/SettingsView+ThemePane.swift",
  "Priority/TaskNavigationService.swift",
  "Priority/TaskTreeFormatter.swift",
  "Priority/Theme.swift",
  "Priority/Typography.swift",

  // Plugin subtrees (AppLogic pulls OfflineTaskSyncPlugin.swift and
  // PluginProtocols.swift as sources; everything else is app-only or lives in
  // PriorityPlugins).
  "Priority/Plugins/Registry",
  "Priority/Plugins/Protocols/PluginProtocols.swift",
  "Priority/Plugins/Protocols/PluginSettingsPageProviding.swift",
  "Priority/Plugins/Protocols/DailyLogPluginProtocol.swift",
  "Priority/Plugins/Protocols/CompletionCelebrationPluginProtocol.swift",
  "Priority/Plugins/Protocols/ThemePluginProtocol.swift",
  "Priority/Plugins/Native/AFFiNE",
  "Priority/Plugins/Native/Celebration",
  "Priority/Plugins/Native/Checkvist",
  "Priority/Plugins/Native/DailyLog",
  "Priority/Plugins/Native/Google",
  "Priority/Plugins/Native/GoogleCalendar",
  "Priority/Plugins/Native/GoogleTasks",
  "Priority/Plugins/Native/MCP",
  "Priority/Plugins/Native/Obsidian",
  "Priority/Plugins/Native/Theme",
  "Priority/Plugins/User",
]

let package = Package(
  name: "priority-core",
  // iOS is for the phone app in `mobile/ios`, which links the workspace
  // packages rather than re-implementing them. The plugin and app-logic targets
  // are only ever built for the Mac.
  platforms: [.macOS(.v15), .iOS(.v18)],
  products: [
    .library(name: "PriorityCore", targets: ["PriorityCore"]),
    .library(name: "PriorityPlugins", targets: ["PriorityPlugins"]),
    .library(name: "PriorityAppLogic", targets: ["PriorityAppLogic"]),
    .library(name: "PriorityWorkspace", targets: ["PriorityWorkspace"]),
    .library(name: "PriorityWorkspaceEditing", targets: ["PriorityWorkspaceEditing"]),
    .library(name: "PrioritySync", targets: ["PrioritySync"]),
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.8.0"),
  ],
  targets: [
    .target(
      name: "PriorityCore",
      path: "Sources/PriorityCore"
    ),
    .target(
      name: "PriorityWorkspace",
      dependencies: [
        "PriorityCore",
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      path: "Sources/PriorityWorkspace"
    ),
    // The client half of multi-device sync (`docs/sync.md`), shared by the Mac
    // and iOS apps. Android has its own in `mobile/android/data`.
    .target(
      name: "PrioritySync",
      dependencies: ["PriorityWorkspace"],
      path: "Sources/PrioritySync"
    ),
    .target(
      name: "PriorityPlugins",
      // Same unlock as `PriorityAppLogic`: these sources compile into the Xcode
      // app as well, and the app now links `PriorityCore` rather than compiling
      // it, so the module resolves on both sides.
      dependencies: ["PriorityCore"],
      path: ".",
      exclude: pluginTargetExcludes,
      sources: [
        "Priority/Plugins/Protocols/PluginProtocols.swift",
        "Priority/Plugins/Native/Checkvist/NativeCheckvistSyncPlugin.swift",
        "Priority/Plugins/Native/Checkvist/CheckvistCredentialStore.swift",
        "Priority/Plugins/Native/Checkvist/CheckvistEndpoints.swift",
        "Priority/Plugins/Native/Checkvist/CheckvistModels.swift",
        "Priority/Plugins/Native/Checkvist/CheckvistTaskCachePayload.swift",
        "Priority/Plugins/Native/Checkvist/CheckvistSessionError.swift",
        "Priority/Plugins/Native/AFFiNE/AFFiNEMCPSession.swift",
        "Priority/Plugins/Native/AFFiNE/AFFiNEExportService.swift",
        "Priority/Plugins/Native/AFFiNE/NativeAFFiNEIntegrationPlugin.swift",
        "Priority/Plugins/Native/Obsidian/ObsidianOpenMode.swift",
        "Priority/Plugins/Native/Obsidian/NativeObsidianIntegrationPlugin.swift",
        "Priority/Plugins/Native/Google/GoogleAccount.swift",
        "Priority/Plugins/Native/Google/GoogleOAuthTokenStore.swift",
        "Priority/Plugins/Native/GoogleCalendar/NativeGoogleCalendarIntegrationPlugin.swift",
        "Priority/Plugins/Native/GoogleTasks/NativeGoogleTasksIntegrationPlugin.swift",
        "Priority/Plugins/Native/MCP/NativeMCPIntegrationPlugin.swift",
        "Priority/Plugins/User/UserPluginManager.swift",
        "Priority/Plugins/User/UserPluginManifest.swift",
        "plugin-tests-support/PluginModelStubs.swift",
      ]
    ),
    .target(
      name: "PriorityWorkspaceEditing",
      dependencies: ["PriorityWorkspace"],
      path: "Priority/Editing"
    ),
    // AppLogic hosts the headless-but-app-bound state machines (TaskRepository,
    // OfflineTaskSyncPlugin, the priority/queue/eisenhower stores, etc.) so they
    // can be exercised by `swift test` without spinning up the Xcode app target.
    // The Checkvist data types and `CheckvistSyncPlugin` protocol are
    // re-declared in `applogic-support/AppLogicSharedTypes.swift` because
    // promoting them out of `PriorityPlugins` would require making them
    // `public` — see the Phase 5.2 note in ARCHITECTURE_IMPROVEMENT_PLAN.md.
    .target(
      name: "PriorityAppLogic",
      // Legal at last. `PriorityAppLogic`'s sources are still compiled into the
      // Xcode app as well as into this target, and an `import PriorityCore`
      // line used to break the app build because no such module existed there.
      // Now the app *links* PriorityCore rather than compiling its sources, so
      // the module exists on both sides and the import resolves either way.
      dependencies: ["PriorityCore"],
      path: ".",
      exclude: appLogicTargetExcludes,
      sources: [
        "Priority/Managers/TaskRepository.swift",
        // Reachable at last: it needs `PriorityCore`'s visibility engines, and
        // this target could not import them until the app started linking the
        // package rather than compiling its sources.
        "Priority/Managers/TaskListViewModel.swift",
        "Priority/CacheState.swift",
        // Conforms the Checkvist model to `PriorityCore`'s `VisibilityTask`.
        // Compiled into both this target and the app, so each side's
        // declaration of `CheckvistTask` picks up the conformance.
        "Priority/CheckvistTask+VisibilityTask.swift",
        "Priority/CacheInvalidationBus.swift",
        "Priority/UndoService.swift",
        "Priority/LocalTaskStore.swift",
        "Priority/OptimisticTaskID.swift",
        "Priority/ReorderQueue.swift",
        "Priority/SyncService.swift",
        "Priority/TaskMutationService.swift",
        "Priority/TaskMutationService+Board.swift",
        "Priority/TaskServiceHosts.swift",
        "Priority/TaskNavigationCoordinator.swift",
        // The outline flattening `TaskNavigationCoordinator` decides against.
        // Pure, and covered by `TaskOutlineBuilderTests`.
        "Priority/TaskOutlineBuilder.swift",
        "Priority/ListScopedPriorityStore.swift",
        "Priority/ListScopedTaskIDStore.swift",
        "Priority/ListScopedEisenhowerStore.swift",
        "Priority/Plugins/Native/OfflineTaskSyncPlugin.swift",
        "Priority/PreferencesStore.swift",
        "Priority/Models/UndoableAction.swift",
        "Priority/Models/CheckvistConnectionState.swift",
        "applogic-support/AppLogicSharedTypes.swift",
      ]
    ),
    .testTarget(
      name: "PriorityCoreTests",
      dependencies: ["PriorityCore"],
      path: "corelogic-tests"
    ),
    .testTarget(
      name: "PriorityPluginTests",
      dependencies: ["PriorityPlugins"],
      path: "plugin-tests"
    ),
    .testTarget(
      name: "PriorityAppLogicTests",
      dependencies: ["PriorityAppLogic", "PriorityPlugins"],
      path: "applogic-tests"
    ),
    .testTarget(
      name: "PriorityWorkspaceTests",
      // GRDB directly, so a migration test can write a fixture database in the
      // shape an older version of the app left behind.
      dependencies: ["PriorityWorkspace", .product(name: "GRDB", package: "GRDB.swift")],
      path: "workspace-tests"
    ),
    .testTarget(
      name: "PriorityWorkspaceEditingTests",
      dependencies: ["PriorityWorkspaceEditing", "PriorityWorkspace"],
      path: "workspace-editing-tests"
    ),
    .testTarget(
      name: "PrioritySyncTests",
      dependencies: ["PrioritySync", "PriorityWorkspace", .product(name: "GRDB", package: "GRDB.swift")],
      path: "sync-tests"
    ),
  ]
)
