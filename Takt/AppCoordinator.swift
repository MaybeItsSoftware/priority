import AppKit
import Foundation
import OSLog
import Observation
import TaktCore
import TaktWorkspace
import ServiceManagement
import SwiftUI

@MainActor
@Observable class AppCoordinator {
  @ObservationIgnored let logger = Logger(
    subsystem: "uk.co.maybeitssoftware.takt", category: "manager")

  /// How the Google Tasks mirror reaches the workspace. Set by `AppDelegate`
  /// once the workspace exists — the coordinator is built first, and the
  /// mirror is only ever used after both of them are up.
  @ObservationIgnored var workspaceStoreProvider: (() -> WorkspaceStore?)?

  /// The Google Tasks mirror. Lazy because it closes over `self`, and because
  /// an installation that never switches it on should never build it.
  /// Watches the events the Calendar integration created, so clearing one off
  /// the calendar completes the task it stood for.
  @ObservationIgnored private(set) lazy var googleCalendarCompletions =
    GoogleCalendarCompletionWatcher(
      plugin: integrations.googleCalendarPlugin,
      storeProvider: { [weak self] in self?.workspaceStoreProvider?() },
      isEnabled: { [weak self] in self?.integrations.googleCalendarIntegrationEnabled ?? false })

  @ObservationIgnored private(set) lazy var googleTasksMirror = GoogleTasksMirrorService(
    plugin: integrations.googleTasksPlugin,
    storeProvider: { [weak self] in self?.workspaceStoreProvider?() },
    isEnabled: { [weak self] in self?.integrations.googleTasksIntegrationEnabled ?? false })

  /// Checkvist as an import source: the account, its lists, and which of
  /// them the workspace copies.
  let checkvist: CheckvistAccount
  /// Copies the Checkvist lists the workspace lacks, now. Set by `AppDelegate`,
  /// which owns the workspace; the settings page's Import button calls it.
  @ObservationIgnored var importCheckvistNow: (() async -> Void)?

  /// Transient one-line feedback under the list. Clears itself after three
  /// seconds.
  ///
  /// The generation token is what makes overlapping messages behave: each
  /// assignment starts its own timer, so without it the *first* message's timer
  /// would fire three seconds later and wipe whatever the second message had
  /// put there — a message set at t=2 vanishing at t=3 instead of t=5.
  var statusMessage: String? {
    didSet {
      guard statusMessage != nil else { return }
      statusMessageGeneration &+= 1
      let generation = statusMessageGeneration
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(3))
        guard self.statusMessageGeneration == generation else { return }
        self.statusMessage = nil
      }
    }
  }

  @ObservationIgnored private var statusMessageGeneration = 0

  enum CarbonKey {
    static let space = 49
    static let b = 11
    static let d = 2
    static let f = 3
    static let n = 45
  }
  enum CarbonModifier {
    static let option = 0x0800
    static let shiftOption = 0x0A00
    /// Command + Shift + Option + Control (the conventional macOS Hyper key).
    static let hyper = 0x1B00
  }

  var integrations: IntegrationCoordinator

  let dailyLog: DailyLogManager
  /// Which completion celebration is active, and the flourish the popover
  /// overlay is currently showing.
  let celebration: CompletionCelebrationManager
  /// Which `ThemePlugin` the app renders through. Like `celebration`, it
  /// retains the registry because the choice is switchable at runtime.
  let theme: ThemeManager
  /// Whether the diagnostics sheet is up. Not persisted: it is something you
  /// open when something is wrong, not a mode you work in. Only the main
  /// window shows it — a sheet needs a titled window to attach to, and the
  /// focus panel is a non-activating one.
  var showsDiagnostics = false
  /// What has failed this session. Nothing else in the app retains a failure
  /// for longer than the three seconds `statusMessage` lasts.
  let diagnosticsLog = DiagnosticsLog()

  let preferences: PreferencesManager

  @ObservationIgnored var isApplyingLaunchAtLoginChange = false
  @ObservationIgnored let preferencesStore = PreferencesStore()
  let userPluginManager: UserPluginManager
  @ObservationIgnored private(set) var lifecycle: LifecycleController!
  /// Where the Checkvist remote key is persisted.
  ///
  /// The key is password-equivalent, so release builds keep it in the keychain
  /// (matching `GoogleCalendarOAuthTokenStore`) rather than in the preferences
  /// plist, which is world-readable by anything running as the user. This was
  /// previously hardcoded to `false`, which not only stored the key in the clear
  /// but also actively migrated it *out* of the keychain on first launch.
  ///
  /// DEBUG builds keep the opt-out (defaulting to on, see `PreferencesManager`)
  /// because locally-signed dev builds get a new signing identity on each
  /// rebuild, which makes macOS prompt for keychain access every run.
  var usesKeychainStorage: Bool {
    #if DEBUG
      return !preferences.ignoreKeychainInDebug
    #else
      return true
    #endif
  }

  init(pluginRegistry: PluginRegistry) {
    let resolvedCheckvistSyncPlugin =
      pluginRegistry.activeCheckvistSyncPlugin ?? NativeCheckvistSyncPlugin()
    // The fallbacks share one account for the same reason the registry's
    // plugins do: two Google integrations, one Google user.
    let fallbackGoogleAccount = GoogleAccount()
    let resolvedGoogleCalendarPlugin =
      pluginRegistry.activeGoogleCalendarPlugin
      ?? NativeGoogleCalendarIntegrationPlugin(account: fallbackGoogleAccount)
    let resolvedGoogleTasksPlugin =
      pluginRegistry.activeGoogleTasksPlugin
      ?? NativeGoogleTasksIntegrationPlugin(account: fallbackGoogleAccount)
    let resolvedMCPIntegrationPlugin =
      pluginRegistry.activeMCPIntegrationPlugin
      ?? NativeMCPIntegrationPlugin()
    let resolvedDailyLogPlugin =
      pluginRegistry.activeDailyLogPlugin
      ?? NativeDailyLogPlugin()

    self.userPluginManager = UserPluginManager(
      builtInPluginIdentifiers: [
        resolvedCheckvistSyncPlugin.pluginIdentifier,
        resolvedGoogleCalendarPlugin.pluginIdentifier,
        resolvedGoogleTasksPlugin.pluginIdentifier,
        resolvedMCPIntegrationPlugin.pluginIdentifier,
        resolvedDailyLogPlugin.pluginIdentifier,
      ]
    )
    self.preferences = PreferencesManager(preferencesStore: preferencesStore)

    // Mirrors `usesKeychainStorage`, which can't be read yet because `self`
    // isn't fully initialized here.
    #if DEBUG
      let useKeychainStorageAtInit = !preferencesStore.bool(.ignoreKeychainInDebug, default: true)
    #else
      let useKeychainStorageAtInit = true
    #endif
    // Returns "" in keychain mode. Reading (or migrating) a keychain item is
    // deliberately deferred until the user explicitly requests saved
    // credentials, so a stale code-signature ACL cannot prompt at launch.
    let initialRemoteKey = resolvedCheckvistSyncPlugin.startupRemoteKey(
      useKeychainStorageAtInit: useKeychainStorageAtInit)
    let checkvist = CheckvistAccount(
      plugin: resolvedCheckvistSyncPlugin,
      preferencesStore: preferencesStore,
      initialRemoteKey: initialRemoteKey)
    self.checkvist = checkvist

    let storedListId = preferencesStore.string(.checkvistListId)
    let storedUsername = preferencesStore.string(.checkvistUsername)
    let storedOnboardingCompletedFlag = preferencesStore.optionalBool(.onboardingCompleted)
    let storedPluginSelectionOnboardingCompletedFlag = preferencesStore.optionalBool(
      .pluginSelectionOnboardingCompleted)

    self.dailyLog = DailyLogManager(
      preferencesStore: preferencesStore,
      plugin: resolvedDailyLogPlugin
    )

    if storedPluginSelectionOnboardingCompletedFlag == nil {
      // The Obsidian task-sync plugin is gone, but whether it was ever
      // switched on still says this is not a first launch.
      let storedObsidianIntegrationEnabled = preferencesStore.optionalBool(
        .obsidianIntegrationEnabled)
      let storedGoogleCalendarIntegrationEnabled = preferencesStore.optionalBool(
        .googleCalendarIntegrationEnabled)
      let storedMCPIntegrationEnabled = preferencesStore.optionalBool(.mcpIntegrationEnabled)
      let hasLegacyState =
        storedOnboardingCompletedFlag != nil
        || !storedUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !storedListId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || storedObsidianIntegrationEnabled != nil
        || storedGoogleCalendarIntegrationEnabled != nil
        || storedMCPIntegrationEnabled != nil
      if hasLegacyState {
        preferencesStore.set(true, for: .pluginSelectionOnboardingCompleted)
      }
    }
    // Retains the registry, unlike the other capabilities: the celebration
    // preset is switchable from Settings, so resolving it once here would pin
    // whatever was active at launch.
    let celebration = CompletionCelebrationManager(
      preferencesStore: preferencesStore,
      registry: pluginRegistry
    )
    self.celebration = celebration
    self.theme = ThemeManager(preferencesStore: preferencesStore, registry: pluginRegistry)
    let integrations = IntegrationCoordinator(
      preferencesStore: preferencesStore,
      googleCalendarPlugin: resolvedGoogleCalendarPlugin,
      googleTasksPlugin: resolvedGoogleTasksPlugin,
      mcpIntegrationPlugin: resolvedMCPIntegrationPlugin
    )
    self.integrations = integrations
    integrations.dataSource = checkvist

    self.lifecycle = LifecycleController(coordinator: self)
    self.lifecycle.start()
    checkvist.usesKeychainStorage = { [weak self] in self?.usesKeychainStorage ?? true }
    checkvist.onCredentialsChanged = { [weak integrations] seedIsStale in
      // The `takt` command was seeded with the account the app signed in
      // with; a new name or a cleared key leaves that seed stale.
      if seedIsStale { integrations?.clearSeededCLICredentials() }
    }
    checkvist.onErrorMessageSet = { [weak self] message in
      self?.diagnosticsLog.record(category: "Checkvist", message: message, isFailure: true)
    }
    dailyLog.onError = { [weak self] message in
      guard let message else { return }
      self?.diagnosticsLog.record(category: "Daily log", message: message, isFailure: true)
      self?.statusMessage = message
    }
    Task { @MainActor [weak self] in
      // Deferred: writing a closed day's note touches the dailies folder,
      // which launch does not need to wait for.
      self?.dailyLog.refreshForToday()
    }
  }

  convenience init() {
    self.init(pluginRegistry: .nativeFirst())
  }

}

extension AppCoordinator {
  // MARK: - Keychain / Debug

  func handleCredentialStorageModeChanged() {
    checkvist.credentialStorageModeChanged()
  }

  @MainActor func resetOnboardingForDebug() {
    #if DEBUG
      checkvist.signOut()
      integrations.clearSeededCLICredentials()
      checkvist.username = ""
      checkvist.defaultListId = ""
      preferencesStore.remove(.checkvistUsername)
      preferencesStore.remove(.checkvistListId)
      preferencesStore.remove(.onboardingCompleted)
      preferencesStore.remove(.pluginSelectionOnboardingCompleted)
      preferencesStore.remove(.dismissedOnboardingDialogs)
    #endif
  }

  var activePluginSettingsPages: [any PluginSettingsPageProviding] {
    [
      checkvist.plugin as any Plugin,
      integrations.googleCalendarPlugin as any Plugin,
      integrations.googleTasksPlugin as any Plugin,
      integrations.mcpIntegrationPlugin as any Plugin,
      dailyLog.plugin as any Plugin,
      // Only the *active* theme, not every registered one: themes are a menu,
      // and listing both would put two cards in the sidebar for one setting.
      // The card's page picks between them.
      theme.activeThemePlugin as any Plugin,
    ].compactMap { $0 as? any PluginSettingsPageProviding }
  }
}
