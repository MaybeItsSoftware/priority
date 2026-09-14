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
  "Sources/PriorityWorkspace",
  "scripts",

  // App resources and the core target's own source tree
  "Priority/Assets.xcassets",
  "Priority/Priority.entitlements",
  "Priority/Priority.release.entitlements",
  "Priority/FocusSessionView.swift",
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
  "Priority/DailyView.swift",
  "Priority/EisenhowerMatrixView.swift",
  "Priority/IntegrationDataSourceAdapter.swift",
  "Priority/KanbanBoardView.swift",
  "Priority/KanbanSettingsView.swift",
  "Priority/KanbanTaskDataSourceAdapter.swift",
  "Priority/KeyboardShortcutRouter.swift",
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
  "Priority/PopoverLayout.swift",
  "Priority/PopoverView.swift",
  "Priority/PopoverView+Dock.swift",
  "Priority/PopoverView+QuickEntryBar.swift",
  "Priority/PopoverView+TaskRow.swift",
  "Priority/ShellModeEnvironment.swift",
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
  "Priority/Plugins/MCP",
  "Priority/Plugins/Registry",
  "Priority/Plugins/Native/OfflineTaskSyncPlugin.swift",
  "Priority/Plugins/Native/Checkvist/CheckvistAPIClient.swift",
  "Priority/Plugins/Native/Checkvist/CheckvistSession.swift",
  "Priority/Plugins/Native/Checkvist/CheckvistTaskRepository.swift",
  "Priority/Plugins/Native/Checkvist/NativeCheckvistSyncPlugin+Settings.swift",
  "Priority/Plugins/Native/GoogleCalendar/GoogleOAuthLoopbackReceiver.swift",
  "Priority/Plugins/Native/GoogleCalendar/NativeGoogleCalendarIntegrationPlugin+Settings.swift",
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
]

// Anything that is *not* an AppLogic source. Mirrors `pluginTargetExcludes` but
// keeps `Priority/Managers/TaskRepository.swift`, the priority/queue stores,
// `OfflineTaskSyncPlugin.swift`, etc. unblocked so SPM can pick them up.
let appLogicTargetExcludes = [
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
  "scripts",

  // App resources and other targets' source trees.
  "Priority/Assets.xcassets",
  "Priority/Priority.entitlements",
  "Priority/Priority.release.entitlements",
  "Priority/FocusSessionView.swift",
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
  "Priority/Managers/TimerManager.swift",

  // Models — AppLogic only wants UndoableAction.swift and CheckvistConnectionState.swift;
  // the rest are app-only enums.
  "Priority/Models/AppThemeModels.swift",
  "Priority/Models/CommandSuggestion.swift",
  "Priority/Models/DailyChartRange.swift",
  "Priority/Models/OnboardingDialog.swift",
  "Priority/Models/QuickAddLocationMode.swift",
  "Priority/Models/QuickEntryMode.swift",

  // App-level source files at Priority/ root that AppLogic does not need.
  "Priority/AppCoordinator.swift",
  "Priority/AppCoordinator+ServiceHosts.swift",
  "Priority/AppDelegate.swift",
  "Priority/AppThemeColorSupport.swift",
  "Priority/CommandExecutor.swift",
  "Priority/DailyLogDataSourceAdapter.swift",
  "Priority/DailyView.swift",
  "Priority/EisenhowerMatrixView.swift",
  "Priority/FocusSessionView.swift",
  "Priority/IntegrationDataSourceAdapter.swift",
  "Priority/KanbanBoardView.swift",
  "Priority/KanbanSettingsView.swift",
  "Priority/KanbanTaskDataSourceAdapter.swift",
  "Priority/KeyboardShortcutRouter.swift",
  "Priority/LifecycleController.swift",
  "Priority/MainApp.swift",
  "Priority/NetworkReachabilityMonitor.swift",
  "Priority/OnboardingService.swift",
  "Priority/DiagnosticsLog.swift",
  "Priority/DiagnosticsView.swift",
  "Priority/MainWindowController.swift",
  "Priority/MainWindowToolbar.swift",
  "Priority/WindowContentSizing.swift",
  "Priority/PopoverLayout.swift",
  "Priority/PopoverView.swift",
  "Priority/PopoverView+Dock.swift",
  "Priority/PopoverView+QuickEntryBar.swift",
  "Priority/PopoverView+TaskRow.swift",
  "Priority/ShellModeEnvironment.swift",
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
  "Priority/Typography.swift",

  // Plugin subtrees (AppLogic pulls OfflineTaskSyncPlugin.swift and
  // PluginProtocols.swift as sources; everything else is app-only or lives in
  // PriorityPlugins).
  "Priority/Plugins/MCP",
  "Priority/Plugins/Registry",
  "Priority/Plugins/Protocols/PluginProtocols.swift",
  "Priority/Plugins/Protocols/PluginSettingsPageProviding.swift",
  "Priority/Plugins/Protocols/DailyLogPluginProtocol.swift",
  "Priority/Plugins/Protocols/CompletionCelebrationPluginProtocol.swift",
  "Priority/Plugins/Native/AFFiNE",
  "Priority/Plugins/Native/Celebration",
  "Priority/Plugins/Native/Checkvist",
  "Priority/Plugins/Native/DailyLog",
  "Priority/Plugins/Native/GoogleCalendar",
  "Priority/Plugins/Native/MCP",
  "Priority/Plugins/Native/Obsidian",
  "Priority/Plugins/User",
]

let package = Package(
  name: "priority-core",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "PriorityCore", targets: ["PriorityCore"]),
    .library(name: "PriorityPlugins", targets: ["PriorityPlugins"]),
    .library(name: "PriorityAppLogic", targets: ["PriorityAppLogic"]),
    .library(name: "PriorityWorkspace", targets: ["PriorityWorkspace"]),
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
        "Priority/Plugins/Native/GoogleCalendar/NativeGoogleCalendarIntegrationPlugin.swift",
        "Priority/Plugins/Native/GoogleCalendar/GoogleCalendarOAuthTokenStore.swift",
        "Priority/Plugins/Native/MCP/NativeMCPIntegrationPlugin.swift",
        "Priority/Plugins/User/UserPluginManager.swift",
        "Priority/Plugins/User/UserPluginManifest.swift",
        "plugin-tests-support/PluginModelStubs.swift",
      ]
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
      dependencies: ["PriorityWorkspace"],
      path: "workspace-tests"
    ),
  ]
)
