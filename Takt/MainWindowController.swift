import AppKit
import OSLog
import TaktCore
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
  private var overlayMouseMonitor: Any?
  private var shortcutShiftTap = DoubleTapModifier()
  private var toolbarController: MainWindowToolbarController?

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
    if let overlayMouseMonitor { NSEvent.removeMonitor(overlayMouseMonitor) }
  }

  // MARK: - Presentation

  func show() {
    let window = makeWindowIfNeeded()
    installWorkspaceKeyMonitorIfNeeded()
    installOverlayMouseMonitorIfNeeded()
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

  var isVisible: Bool { window?.isVisible ?? false }

  /// Puts the window away without ending the session. The counterpart to
  /// `show()` for a quit that is meant to leave the menu bar behind.
  func hide() {
    guard let window, window.isVisible else { return }
    window.close()
  }

  private func makeWindowIfNeeded() -> NSWindow {
    if let window { return window }

    let rootView = WorkspaceDesktopView()
      .focusEffectDisabled()
      .themedBodyFont()
      .environment(workspace)
      .environment(manager)
      .environment(manager.navigationState)
      .environment(manager.taskListViewModel)
      .environment(manager.repository)
      .frame(minWidth: Self.minContentSize.width, minHeight: Self.minContentSize.height)
      .themed(manager.theme)
    let hostingController = NSHostingController(rootView: rootView)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Takt"
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

    // The strip that names which mode you are in. Without it the four of them
    // were reachable only by a command-digit, and nothing on screen said which
    // one you were looking at.
    let toolbarController = MainWindowToolbarController(workspace: workspace, theme: manager.theme)
    self.toolbarController = toolbarController
    window.toolbar = toolbarController.makeToolbar()
    // Compact: the bar holds one strip, and a full-height unified bar spent
    // twenty points on nothing above every pane.
    window.toolbarStyle = .unifiedCompact

    window.setFrameAutosaveName("PriorityMainWindowV1")
    WindowContentSizing.enforce(
      on: window,
      minContentSize: Self.minContentSize,
      maxContentSize: nil
    )
    // The autosave name has just restored whatever frame was saved, which may
    // be on a monitor that is no longer attached.
    clampToVisibleScreens(window)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(screenParametersDidChange(_:)),
      name: NSApplication.didChangeScreenParametersNotification,
      object: nil
    )

    self.window = window
    return window
  }

  /// Moves the window back onto a screen if its title bar is on none of them.
  /// A no-op for a window that is already reachable, so it is safe to run on
  /// every screen change rather than only when something was unplugged.
  private func clampToVisibleScreens(_ window: NSWindow) {
    // `screens.first` is the one with the menu bar, which is where a
    // stranded window should land.
    let visibleFrames = NSScreen.screens.map(\.visibleFrame)
    let clamped = WindowFrameClamp.clamp(
      window.frame,
      visibleFrames: visibleFrames,
      minSize: window.minSize
    )
    if clamped != window.frame {
      window.setFrame(clamped, display: window.isVisible)
    }
  }

  /// A monitor unplugged while the window is open leaves it wherever that
  /// monitor was; macOS usually rescues it, but not reliably for a window
  /// that was spanning two displays.
  @objc private func screenParametersDidChange(_ notification: Notification) {
    guard let window else { return }
    clampToVisibleScreens(window)
  }

  // MARK: - Keyboard

  /// Desktop navigation deliberately ignores text responders, so task titles
  /// and notes retain normal macOS editing. Every other key is routed to the
  /// local workspace — never the old menu-bar/Checkvist command router.
  ///
  /// The monitor stays live while an overlay is up — the palette, search, the
  /// list finder — and offers it every key first. That is what lets ⌘K open
  /// the palette from inside search, which no sheet could: an attached sheet
  /// is a second window, and this monitor stands down for one.
  private func installWorkspaceKeyMonitorIfNeeded() {
    guard workspaceKeyMonitor == nil else { return }
    workspaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
      guard let self, let window = self.window, window.isVisible,
        window.attachedSheet == nil, event.window === window else {
        return event
      }
      if event.type == .flagsChanged {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if self.shortcutShiftTap.modifierChanged(isDown: flags.contains(.shift),
          otherModifiersHeld: !flags.subtracting(.shift).isEmpty, at: event.timestamp),
          !self.isEditingText(in: window) {
          self.workspace.desktopShortcutSequence.reset()
          // Checkvist's ⇧⇧ opens its command palette, and this app had no
          // palette to open, so it raised the reference sheet instead. Now
          // there is one, the gesture means what it means everywhere else.
          self.workspace.run(.goCommandPalette)
          return nil
        }
        return event
      }
      self.shortcutShiftTap.keyPressed()
      if self.workspace.activeOverlay != nil {
        self.workspace.desktopShortcutSequence.reset()
        // Nothing an overlay leaves unconsumed reaches the workspace behind
        // it: it goes to the overlay's own field, or nowhere.
        return self.workspace.handleOverlayKey(event) ? nil : event
      }
      // The agent panel is treated as a field as a whole, not only its text
      // view: an approval card holding the keyboard answers Return itself,
      // and a Return that fell through to the workspace would open whatever
      // task was selected behind it instead.
      // Tab in the row a new task is typed into indents it under the task
      // above, ⇧Tab takes it back out. The field editor would otherwise take
      // Tab to move focus before the row's own handler ever heard it.
      if event.keyCode == 48, self.isEditingText(in: window), self.workspace.isDraftingTask,
        event.modifierFlags.isDisjoint(with: [.command, .option, .control]) {
        if event.modifierFlags.contains(.shift) {
          self.workspace.outdentTaskDraft()
        } else {
          self.workspace.indentTaskDraft()
        }
        return nil
      }
      if self.isEditingText(in: window) || self.workspace.agentHoldsKeyboard {
        self.workspace.desktopShortcutSequence.reset()
        // Only the chords that are how you leave a field to do something else
        // — the views, the regions, creating, search, the palette, the
        // reference. The catalogue says which (`reachableFromTextField`), so
        // this list cannot drift from the keys it names. ⌘Z is deliberately
        // not one: inside a field it belongs to the text being typed.
        guard let key = event.workspaceCommandKey,
          WorkspaceCommandCatalog.reachesIntoTextField(key, on: self.workspace.commandSurface)
        else {
          return self.keepInField(event, in: window) ? nil : event
        }
      }
      return self.workspace.handleDesktopKey(event) ? nil : event
    }
  }

  // MARK: - Overlay dismissal

  /// Closes the overlay on a mouse-down anywhere in the window but its card.
  ///
  /// A monitor rather than a SwiftUI tap-catcher behind the card, because the
  /// sidebar and the outline are AppKit tables: AppKit gives a click to the
  /// deepest `NSView` under it, so a catcher layered over them never heard
  /// it. The monitor sees the event before any view does.
  ///
  /// A click over the content is consumed, so dismissing the palette does not
  /// also select whatever row was underneath. A click in the title bar or the
  /// toolbar closes the overlay and still goes through, so the traffic lights,
  /// the mode strip and dragging the window all work first time.
  private func installOverlayMouseMonitorIfNeeded() {
    guard overlayMouseMonitor == nil else { return }
    overlayMouseMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    ) { [weak self] event in
      guard let self, let window = self.window, event.window === window,
        window.attachedSheet == nil, self.workspace.activeOverlay != nil,
        let content = window.contentView else {
        return event
      }
      var point = content.convert(event.locationInWindow, from: nil)
      // SwiftUI's global space runs top-down from the content's top-left.
      if !content.isFlipped { point.y = content.bounds.height - point.y }
      if let panel = self.workspace.overlayPanelFrame, panel.contains(point) {
        return event
      }
      self.workspace.dismissOverlay()
      return content.bounds.contains(content.convert(event.locationInWindow, from: nil))
        ? nil : event
    }
  }

  /// Hands a chord the menu bar would otherwise take straight to the field
  /// being typed in.
  ///
  /// Menu shortcuts are matched before the focused view sees the key, so the
  /// Task menu's ⌘⌫ asked to delete the selected task while you were clearing
  /// a line, and its ⌥← ⌥→ indented a task instead of moving the cursor a
  /// word. Inside a field those keys are the field's. Undo and redo keep their
  /// own menu items, which already know about fields.
  private func keepInField(_ event: NSEvent, in window: NSWindow) -> Bool {
    guard let key = event.workspaceCommandKey,
      !event.modifierFlags.isDisjoint(with: [.command, .option, .control]),
      let command = WorkspaceCommandCatalog.command(forKey: key, on: workspace.commandSurface),
      command.id != .windowUndo, command.id != .windowRedo,
      let editor = window.firstResponder as? NSTextView
    else { return false }
    editor.keyDown(with: event)
    return true
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
