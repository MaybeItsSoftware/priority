import AppKit
import Combine
import OSLog
import Observation
import PriorityCore
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

  static private(set) var shared: AppDelegate!

  override init() {
    super.init()
    Self.shared = self
  }

  private let pluginRegistry = PluginRegistry.nativeFirst()
  lazy var checkvistManager: AppCoordinator = AppCoordinator(
    pluginRegistry: pluginRegistry)

  private(set) var menuBarController: MenuBarController!
  private(set) var shortcutManager: GlobalShortcutManager!
  private(set) var mainWindowController: MainWindowController!
  private(set) var workspace: WorkspaceViewModel!

  private var preferencesWindow: NSWindow?
  private var preferencesNavState: SettingsNavState?
  private var cancellables = Set<AnyCancellable>()
  private var explicitQuitRequested = false
  private var lastAutoRefreshTime: Date = Date.distantPast
  private let logger = Logger(subsystem: "uk.co.maybeitsadam.priority", category: "appdelegate")

  #if DEBUG
    private var isRunningFromXcode: Bool {
      let env = ProcessInfo.processInfo.environment
      return env["XCODE_VERSION_ACTUAL"] != nil || env["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil
    }
  #endif

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Before anything reads preferences or the day log — including the MCP
    // server, which reads both and would otherwise answer from an empty store
    // for any client that launched it before the app had ever been opened.
    LegacyNameMigration.runIfNeeded()

    // Priority is a desktop app first. The status item remains available as a
    // compact utility surface, but it no longer owns the initial experience.
    NSApp.setActivationPolicy(.regular)
    applyAppTheme()

    menuBarController = MenuBarController(manager: checkvistManager)
    menuBarController.onShowSettings = { [weak self] in
      self?.menuSettings()
    }
    menuBarController.onShowMainWindow = { [weak self] in
      self?.showMainWindow()
    }
    menuBarController.onQuit = { [weak self] in
      self?.menuQuit()
    }
    menuBarController.usesDesktopWorkspace = true

    checkvistManager.focusSessionManager.onAlert = { [weak self] in
      guard let self else { return }
      self.showMainWindow()
      if let sound = NSSound(named: NSSound.Name("Glass")) {
        sound.play()
      } else {
        NSSound.beep()
      }
    }

    workspace = WorkspaceViewModel(legacyStore: checkvistManager.repository.localTaskStore)
    mainWindowController = MainWindowController(manager: checkvistManager, workspace: workspace)
    mainWindowController.onUpdateMenuBarTitle = { [weak self] in
      self?.menuBarController.updateTitle()
    }
    mainWindowController.onShowSettings = { [weak self] in
      self?.menuSettings()
    }
    mainWindowController.onVisibilityChanged = { [weak self] isVisible in
      self?.applyActivationPolicy(hasOrdinaryWindow: isVisible)
    }

    shortcutManager = GlobalShortcutManager(manager: checkvistManager)
    shortcutManager.onTogglePopover = { [weak self] in
      self?.mainWindowController.toggle()
    }
    shortcutManager.onQuickAdd = { [weak self] in
      self?.triggerQuickAddFromHotkey()
    }

    observeForAppThemeChanges()

    // Constructing the workspace above also imports the old offline payload
    // into its local SQLite database before this first presentation.
    showMainWindow()

    NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.scheduleAutoRefresh()
      }
      .store(in: &cancellables)

    NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.scheduleAutoRefresh()
      }
      .store(in: &cancellables)

    Task { [weak self] in
      try? await Task.sleep(nanoseconds: 500_000_000)
      guard let self else { return }
      await self.checkvistManager.syncService.fetchTopTask()
      self.menuBarController.updateTitle()
    }
  }

  private func applyAppTheme() {
    switch checkvistManager.preferences.appTheme {
    case .system:
      NSApp.appearance = nil
    case .light:
      NSApp.appearance = NSAppearance(named: .aqua)
    case .dark:
      NSApp.appearance = NSAppearance(named: .darkAqua)
    }
  }

  func menuSettings() {
    menuSettings(pane: nil)
  }

  func menuSettings(pane: SettingsNavState.Pane?) {
    let window = makePreferencesWindowIfNeeded()
    if let pane {
      preferencesNavState?.select(pane: pane)
    }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func makePreferencesWindowIfNeeded() -> NSWindow {
    if let preferencesWindow {
      return preferencesWindow
    }

    let navState = SettingsNavState()
    preferencesNavState = navState

    let rootView = SettingsView()
      .font(Typography.interfaceFont)
      .environment(checkvistManager)
      .environment(navState)
      .frame(minWidth: 720, idealWidth: 820, minHeight: 560, idealHeight: 660)
    let hostingController = NSHostingController(rootView: rootView)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 820, height: 660),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Preferences"
    window.titleVisibility = .hidden
    window.toolbarStyle = .preference
    let toolbar = NSToolbar(identifier: "PriorityPreferencesToolbar")
    toolbar.delegate = navState
    toolbar.displayMode = .iconAndLabel
    toolbar.allowsUserCustomization = false
    toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(
      SettingsNavState.Pane.preferences.rawValue)
    navState.toolbar = toolbar
    window.toolbar = toolbar
    window.center()
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.tabbingMode = .disallowed
    window.delegate = self
    window.contentViewController = hostingController
    window.setFrameAutosaveName("PriorityPreferencesWindowV2")
    WindowContentSizing.enforce(
      on: window,
      minContentSize: Self.preferencesMinContentSize,
      maxContentSize: Self.preferencesMaxContentSize
    )
    preferencesWindow = window
    return window
  }

  /// Minimum *content* size the settings root asks for, matching the
  /// `.frame(minWidth:minHeight:)` on `SettingsView` above.
  private static let preferencesMinContentSize = NSSize(width: 720, height: 560)
  private static let preferencesMaxContentSize = NSSize(width: 1200, height: 900)

  func windowWillClose(_ notification: Notification) {
    guard let closingWindow = notification.object as? NSWindow else { return }
    if closingWindow === preferencesWindow {
      preferencesWindow = nil
      preferencesNavState = nil
    }
  }

  private func scheduleAutoRefresh() {
    let now = Date()
    guard
      AutoRefreshThrottlePolicy.shouldRefresh(
        needsInitialSetup: checkvistManager.needsInitialSetup,
        now: now,
        lastRefreshAt: lastAutoRefreshTime
      )
    else { return }
    lastAutoRefreshTime = now
    Task { [weak self] in
      await self?.checkvistManager.syncService.fetchTopTask()
      self?.menuBarController.updateTitle()
    }
  }

  func showMainWindow() {
    mainWindowController.show()
  }

  /// The Dock icon and the app menu are process-wide, not per-window, so they
  /// are derived from whether any ordinary window is up rather than toggled at
  /// each call site.
  ///
  /// `.regular` is what gives a windowed user Cmd-Tab, Cmd-W and — the one that
  /// bites if it is missing — the Edit menu, without which copy and paste do
  /// nothing in the quick-entry field.
  /// - Parameter hasOrdinaryWindow: passed in rather than re-derived from the
  ///   window, because `windowWillClose` arrives *before* the window stops
  ///   reporting itself visible — asking it would have left the Dock icon
  ///   behind after every close.
  private func applyActivationPolicy(hasOrdinaryWindow: Bool) {
    let desired: NSApplication.ActivationPolicy = hasOrdinaryWindow ? .regular : .accessory
    guard NSApp.activationPolicy() != desired else { return }
    NSApp.setActivationPolicy(desired)
    if desired == .regular {
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  func menuQuit() {
    explicitQuitRequested = true
    NSApp.terminate(nil)
  }

  private func triggerQuickAddFromHotkey() {
    showMainWindow()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    switch AppTerminationPolicy.decision(
      explicitQuitRequested: explicitQuitRequested,
      isRegularActivationPolicy: NSApp.activationPolicy() == .regular
    ) {
    case .terminateNow:
      return .terminateNow
    case .cancel:
      break
    }
    return .terminateCancel
  }

  func applicationWillTerminate(_ notification: Notification) {
    // Optional because termination can arrive before the manager is built —
    // reaching through an implicitly-unwrapped optional here used to crash the
    // MCP server on shutdown, back when `--mcp-server` ran inside this app.
    shortcutManager?.unregisterGlobalHotkeys()
  }

  private func observeForAppThemeChanges() {
    withObservationTracking {
      _ = self.checkvistManager.preferences.appTheme
    } onChange: {
      Task { @MainActor [weak self] in
        self?.applyAppTheme()
        self?.observeForAppThemeChanges()
      }
    }
  }
}
