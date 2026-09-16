import AppKit
import OSLog
import PriorityCore
import SwiftUI

/// The ordinary, resizable window for Priority's local-first workspace.
///
/// The menu bar deliberately keeps its compact compatibility surface while the
/// desktop window owns independent local navigation and editing state. Shared
/// services remain in `AppCoordinator`; a shared task cursor does not.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {

  /// Matches the `.frame(minWidth:minHeight:)` on the hosted root below.
  private static let minContentSize = NSSize(width: 760, height: 520)

  private let manager: AppCoordinator
  private let workspace: WorkspaceViewModel
  private var window: NSWindow?
  private var workspaceKeyMonitor: Any?

  /// Refreshes the menu bar title. Shared state means the window moving the
  /// cursor has to move the status item's label too, exactly as the panel does.
  var onUpdateMenuBarTitle: (() -> Void)?
  var onShowSettings: (() -> Void)?
  /// Told when the window opens and closes, so the activation policy — a
  /// process-wide setting, not a per-window one — is decided in one place.
  var onVisibilityChanged: ((Bool) -> Void)?

  init(manager: AppCoordinator, workspace: WorkspaceViewModel) {
    self.manager = manager
    self.workspace = workspace
    super.init()
  }

  deinit {
    if let workspaceKeyMonitor { NSEvent.removeMonitor(workspaceKeyMonitor) }
  }

  // MARK: - Presentation

  func show() {
    let window = makeWindowIfNeeded()
    installWorkspaceKeyMonitorIfNeeded()
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

    let rootView = WorkspaceDesktopView()
      .font(Typography.interfaceFont)
      .environment(workspace)
      .environment(manager)
      .environment(manager.navigationState)
      .environment(manager.taskListViewModel)
      .environment(manager.repository)
      .frame(minWidth: Self.minContentSize.width, minHeight: Self.minContentSize.height)
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

    window.toolbarStyle = .unified

    window.setFrameAutosaveName("PriorityMainWindowV1")
    WindowContentSizing.enforce(
      on: window,
      minContentSize: Self.minContentSize,
      maxContentSize: nil
    )

    self.window = window
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

  /// Desktop navigation deliberately ignores text responders, so task titles,
  /// notes, search fields, and creation sheets retain normal macOS editing.
  /// Every other key is routed to the local workspace — never the old
  /// menu-bar/Checkvist command router.
  private func installWorkspaceKeyMonitorIfNeeded() {
    guard workspaceKeyMonitor == nil else { return }
    workspaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, let window = self.window, window.isVisible, event.window === window else {
        return event
      }
      if self.isEditingText(in: window) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let character = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let regionOrView = flags == [.command] && character.count == 1
          && "012345678".contains(character)
        let cycleRegion = (flags == [.control] || flags == [.control, .shift]) && event.keyCode == 48
        let createItem = (flags == [.command] || flags == [.command, .shift]
          || flags == [.command, .option]) && character == "n"
        let chooseDestination = flags == [.command, .option]
          && (character == "[" || character == "]")
        let help = flags == [.command] && character == "/"
        // Search, but deliberately not undo: inside a text field ⌘Z belongs to
        // the text being typed, not to the workspace behind it.
        let search = flags == [.command] && character == "f"
        guard regionOrView || cycleRegion || createItem || chooseDestination || help || search else {
          return event
        }
      }
      return self.workspace.handleDesktopKey(event) ? nil : event
    }
  }

  private func isEditingText(in window: NSWindow) -> Bool {
    var responder: NSResponder? = window.firstResponder
    while let current = responder {
      if current is NSTextView || current is NSTextField { return true }
      responder = current.nextResponder
    }
    return false
  }

  // MARK: - NSWindowDelegate

  func windowWillClose(_ notification: Notification) {
    guard (notification.object as? NSWindow) === window else { return }
    manager.popoverChrome.showsDiagnostics = false
    onVisibilityChanged?(false)
  }
}
