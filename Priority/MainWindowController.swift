import AppKit
import OSLog
import PriorityCore
import SwiftUI

/// The ordinary, resizable window onto the same task UI the menu bar panel shows.
///
/// It hosts `PopoverView` unchanged — only `\.shellMode` differs — because every
/// member of `PopoverView+Dock`, `+TaskRow` and `+QuickEntryBar` is an extension
/// on that one type, so a separate window root would mean moving all of them.
///
/// State is shared with the panel rather than duplicated: `TaskListViewModel`'s
/// cache is derived from the root view, the hide-future flag, the search text
/// and the `NavigationState` cursor, so a second view model showing a different
/// tab is not something one `AppCoordinator` can serve. The two surfaces are
/// deliberately mirrors of each other.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {

  /// Matches the `.frame(minWidth:minHeight:)` on the hosted root below.
  private static let minContentSize = NSSize(width: 560, height: 420)

  private let manager: AppCoordinator
  private let logger = Logger(subsystem: "uk.co.maybeitsadam.priority", category: "main-window")
  private var window: NSWindow?
  private var keyMonitor: Any?
  private var toolbarController: MainWindowToolbarController?

  /// Refreshes the menu bar title. Shared state means the window moving the
  /// cursor has to move the status item's label too, exactly as the panel does.
  var onUpdateMenuBarTitle: (() -> Void)?
  var onShowSettings: (() -> Void)?
  /// Told when the window opens and closes, so the activation policy — a
  /// process-wide setting, not a per-window one — is decided in one place.
  var onVisibilityChanged: ((Bool) -> Void)?

  init(manager: AppCoordinator) {
    self.manager = manager
    super.init()
  }

  deinit {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    if let shiftMonitor { NSEvent.removeMonitor(shiftMonitor) }
  }

  // MARK: - Presentation

  func show() {
    let window = makeWindowIfNeeded()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    onVisibilityChanged?(true)
    // The same "the user is here" signal the panel sends: idempotent within a
    // logical day, and the only place the day's plan gets snapshotted.
    manager.dailyLog.refreshForToday()
  }

  func toggle() {
    if let window, window.isVisible {
      window.close()
    } else {
      show()
    }
  }

  private func makeWindowIfNeeded() -> NSWindow {
    if let window { return window }

    let rootView =
      PopoverView()
      .font(Typography.interfaceFont)
      .environment(manager)
      .environment(manager.navigationState)
      .environment(manager.taskListViewModel)
      .environment(manager.repository)
      .environment(\.shellMode, .window)
      .frame(
        minWidth: Self.minContentSize.width,
        minHeight: Self.minContentSize.height
      )
    let hostingController = NSHostingController(rootView: rootView)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Priority"
    window.contentViewController = hostingController
    // Deliberately *not* `backgroundColor = .clear` the way the panel is: that
    // is what lets the panel's SwiftUI-drawn rounded background be the only
    // thing on screen. In a titled window it would composite the theme colour
    // over the window's own and show through at the corners.
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    // One window. Tabs would each need their own cursor and root view, which is
    // exactly what the shared view model cannot provide.
    window.tabbingMode = .disallowed
    window.delegate = self
    window.center()

    let toolbarController = MainWindowToolbarController(manager: manager)
    toolbarController.onRefresh = { [weak self] in self?.refresh() }
    toolbarController.onShowSettings = { [weak self] in self?.onShowSettings?() }
    toolbarController.onShowDiagnostics = { [weak self] in
      self?.manager.popoverChrome.showsDiagnostics = true
    }
    window.toolbar = toolbarController.makeToolbar()
    self.toolbarController = toolbarController

    window.setFrameAutosaveName("PriorityMainWindowV1")
    WindowContentSizing.enforce(
      on: window,
      minContentSize: Self.minContentSize,
      maxContentSize: nil
    )

    self.window = window
    installKeyMonitorIfNeeded()
    return window
  }

  private func refresh() {
    Task { [weak self] in
      guard let self else { return }
      await self.manager.syncService.fetchTopTask()
      self.onUpdateMenuBarTitle?()
    }
  }

  // MARK: - Keyboard

  /// A monitor of our own rather than a shared one filtered two ways: the panel
  /// already installs one keyed to its window, and both bail on any event not
  /// destined for them, so keys in Preferences still fall through untouched.
  private func installKeyMonitorIfNeeded() {
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, let window = self.window, window.isVisible else { return event }
      guard event.window === window else { return event }
      self.shiftTaps.keyPressed()
      return self.handle(event: event) ? nil : event
    }
    installShiftMonitorIfNeeded()
  }

  private var shiftMonitor: Any?
  private var shiftTaps = DoubleTapModifier()

  /// ⇧⇧ opens the command palette, as it does in Checkvist.
  ///
  /// A modifier alone produces no key-down, so this cannot be a binding in
  /// `ConfigurableShortcutAction` — it is a separate monitor over flag changes,
  /// with the key-down monitor feeding it so that Shift held for a capital
  /// letter is a chord rather than a tap. See `DoubleTapModifier`.
  private func installShiftMonitorIfNeeded() {
    guard shiftMonitor == nil else { return }
    shiftMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      guard let self, let window = self.window, window.isVisible else { return event }
      guard event.window === window else { return event }
      let flags = event.modifierFlags
      let fired = self.shiftTaps.modifierChanged(
        isDown: flags.contains(.shift),
        otherModifiersHeld: !flags.isDisjoint(with: [.command, .option, .control]),
        at: event.timestamp
      )
      if fired { self.openCommandPalette() }
      // Never consumed: other views still need to know about Shift.
      return event
    }
  }

  private func openCommandPalette() {
    manager.quickEntry.keyBuffer = ""
    manager.quickEntry.quickEntryMode = .command
    manager.quickEntry.quickEntryText = ""
    manager.quickEntry.commandSuggestionIndex = 0
    manager.quickEntry.isQuickEntryFocused = true
  }

  private func handle(event: NSEvent) -> Bool {
    let router = KeyboardShortcutRouter(
      manager: manager,
      logger: logger,
      updateTitle: { [weak self] in self?.onUpdateMenuBarTitle?() },
      // Escape cancels input and then stops. `ShortcutGate` only reaches
      // `.closeWindow` once there is nothing left to cancel, and a window that
      // vanished on Escape would be a worse answer than one that did nothing.
      closeWindow: {}
    )
    return router.handle(event: event, hostWindow: window)
  }

  // MARK: - NSWindowDelegate

  func windowWillClose(_ notification: Notification) {
    guard (notification.object as? NSWindow) === window else { return }
    manager.popoverChrome.showsDiagnostics = false
    onVisibilityChanged?(false)
  }
}
