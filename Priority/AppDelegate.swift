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
  private(set) var focusPanelController = FocusPanelController()
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
    menuBarController.onShowFocusPanel = { [weak self] in
      self?.showFocusPanel()
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
    workspace.googleCalendarEventCreator = { [weak checkvistManager] title, taskID, listTitle, date, isAllDay in
      guard let integrations = checkvistManager?.integrations else { return nil }
      return try await integrations.createGoogleCalendarEvent(
        title: title, taskID: taskID, listTitle: listTitle, date: date, isAllDay: isAllDay)
    }
    // The mirror needs the workspace, and the workspace has only just been
    // built — the coordinator is constructed before it.
    checkvistManager.workspaceStoreProvider = { [weak workspace] in workspace?.store }
    workspace.onLocalWrite = { [weak checkvistManager] in
      checkvistManager?.googleTasksMirror.scheduleSync()
    }
    workspace.onGoogleCalendarEventCreated = { [weak checkvistManager] taskID, eventID in
      checkvistManager?.googleCalendarCompletions.watch(eventID: eventID, forTask: taskID)
    }
    checkvistManager.googleTasksMirror.startPolling()
    checkvistManager.googleCalendarCompletions.startPolling()
    // One pass at launch, so anything ticked off on a phone while the app was
    // closed lands before the first thing you look at.
    checkvistManager.integrations.googleTasksPlugin.prepareAuthentication()
    Task { [weak checkvistManager] in await checkvistManager?.googleTasksMirror.sync() }
    mainWindowController = MainWindowController(manager: checkvistManager, workspace: workspace)
    // The status item reports the focus session, which is the one thing worth
    // showing there while you are working in another app.
    menuBarController.workspace = workspace
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
    shortcutManager.onToggleFocusPanel = { [weak self] in
      guard let self else { return }
      self.focusPanelController.toggle(model: self.workspace)
    }

    observeForAppThemeChanges()

    // What to do next is the question the app exists to answer, so it is the
    // one the first screen asks. Decided before the window is built rather
    // than after, so the lists never flash up behind it.
    if checkvistManager.preferences.opensOnFocusScreen {
      workspace.presentFocusScreen()
    }

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
      let listsLoaded = await self.checkvistManager.syncService.loadCheckvistLists()
      await self.checkvistManager.syncService.fetchTopTask()
      self.workspace.importLegacyCheckvistTasks(
        self.checkvistManager.repository.tasks,
        sourceListID: self.checkvistManager.repository.listId)
      if listsLoaded {
        let snapshots = await self.checkvistWorkspaceSnapshots()
        self.workspace.importCheckvistLists(snapshots)
      }
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
      .focusEffectDisabled()
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
      guard let self else { return }
      let listsLoaded = await self.checkvistManager.syncService.loadCheckvistLists()
      await self.checkvistManager.syncService.fetchTopTask()
      self.workspace.importLegacyCheckvistTasks(
        self.checkvistManager.repository.tasks,
        sourceListID: self.checkvistManager.repository.listId)
      if listsLoaded {
        let snapshots = await self.checkvistWorkspaceSnapshots()
        self.workspace.importCheckvistLists(snapshots)
      }
      self.menuBarController.updateTitle()
    }
  }

  /// Fetch every discovered list without changing the user's active legacy
  /// Checkvist selection. The workspace receives a local snapshot only; its
  /// regular task editing remains independent from the remote service.
  private func checkvistWorkspaceSnapshots() async -> [(list: CheckvistList, tasks: [CheckvistTask])] {
    let repository = checkvistManager.repository
    var snapshots: [(list: CheckvistList, tasks: [CheckvistTask])] = []
    for list in repository.availableLists {
      let tasks = (try? await repository.fetchCheckvistOpenTasks(listId: String(list.id))) ?? []
      snapshots.append((list: list, tasks: tasks))
    }
    return snapshots
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
    } else if focusPanelController.isVisible {
      // Changing policy resigns the app's active state, and the panel's
      // keyboard focus goes with it. Closing the main window while the panel
      // is up must not reach into the panel — the whole point of the panel is
      // that it does not depend on the window.
      focusPanelController.takeKey()
    }
  }

  func menuQuit() {
    explicitQuitRequested = true
    NSApp.terminate(nil)
  }

  /// The global hotkey is capture, not navigation: wherever the user was, and
  /// whatever they were looking at, what they type next has to land somewhere
  /// they will find it again.
  private func triggerQuickAddFromHotkey() {
    showMainWindow()
    workspace.beginQuickCapture()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    switch AppTerminationPolicy.decision(
      explicitQuitRequested: explicitQuitRequested,
      isRegularActivationPolicy: NSApp.activationPolicy() == .regular
    ) {
    case .terminateNow:
      return .terminateNow
    case .dismissToMenuBar:
      // Flush first: from here on the app is only a status item, and a draft
      // left in an editor that is about to be closed is a draft lost.
      workspace?.taskEditor.flush()
      focusPanelController.dismiss(.back)
      mainWindowController.hide()
    case .cancel:
      break
    }
    return .terminateCancel
  }

  /// Shows the summoned focus panel, whatever else is on screen. The menu
  /// bar uses this too, so the hotkey is a shortcut for something visible
  /// rather than the only way to reach it.
  func showFocusPanel() {
    focusPanelController.show(model: workspace)
  }

  func applicationWillTerminate(_ notification: Notification) {
    workspace?.taskEditor.flush()
    workspace?.pauseFocus()
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
