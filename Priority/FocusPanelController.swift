import AppKit
import SwiftUI

/// The focus panel: the app's one surface you can reach without going to the
/// app.
///
/// It is summoned by a global hotkey over whatever you are actually doing,
/// answers "what am I on / what next", and gets out of the way. That is why it
/// is a floating panel rather than the main window — the point is to decide
/// something in three seconds and go back, not to arrive somewhere.
///
/// The window the hotkey interrupted is restored when the panel is dismissed
/// deliberately, so summoning it out of an editor and pressing Escape puts the
/// caret back where it was. It is not restored when the panel loses key
/// because the user went somewhere else themselves; they have already chosen
/// where they want to be.
@MainActor
final class FocusPanelController: NSObject, NSWindowDelegate {
  /// Wide enough for a task title at a readable size, short enough that it
  /// reads as a panel rather than a second window.
  private static let size = NSSize(width: 640, height: 430)
  /// How far down the screen the panel's top edge sits. Slightly above centre,
  /// the way every summoned field on this platform is.
  private static let verticalAnchor: CGFloat = 0.22

  private var panel: FocusPanelWindow?
  private var interruptedApp: NSRunningApplication?

  var isVisible: Bool { panel?.isVisible ?? false }

  func toggle(model: WorkspaceViewModel) {
    if isVisible { dismiss() } else { show(model: model) }
  }

  func show(model: WorkspaceViewModel) {
    let panel = makePanelIfNeeded(model: model)
    if !NSApp.isActive { interruptedApp = NSWorkspace.shared.frontmostApplication }
    position(panel)
    // The panel carries a text field that is meant to be typed into the
    // instant it appears, and a window of an inactive app does not reliably
    // hold a caret. Activating is what makes "just start typing" true.
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    model.reloadNextUp()
  }

  /// Dismissal the user asked for: Escape, the hotkey again, or finishing
  /// something. Hands the keyboard back to whatever was interrupted.
  func dismiss() {
    panel?.orderOut(nil)
    if let interruptedApp, interruptedApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
      interruptedApp.activate()
    }
    interruptedApp = nil
  }

  // MARK: - The window

  private func makePanelIfNeeded(model: WorkspaceViewModel) -> FocusPanelWindow {
    if let panel { return panel }
    let panel = FocusPanelWindow(
      contentRect: NSRect(origin: .zero, size: Self.size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.isMovableByWindowBackground = true
    // The rounded background is drawn in SwiftUI, so the window itself must
    // not paint its own square one underneath it.
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.delegate = self
    panel.contentViewController = NSHostingController(
      rootView: FocusPanelView(onDismiss: { [weak self] in self?.dismiss() })
        .focusEffectDisabled()
        .font(Typography.interfaceFont)
        .environment(model))
    self.panel = panel
    return panel
  }

  private func position(_ panel: NSPanel) {
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
      ?? NSScreen.main
    guard let frame = screen?.visibleFrame else { panel.center(); return }
    let origin = NSPoint(
      x: frame.midX - Self.size.width / 2,
      y: frame.maxY - frame.height * Self.verticalAnchor - Self.size.height)
    panel.setFrame(NSRect(origin: origin, size: Self.size), display: false)
  }

  // MARK: - NSWindowDelegate

  func windowDidResignKey(_ notification: Notification) {
    guard (notification.object as? NSWindow) === panel else { return }
    // Clicking away is its own answer. Order out, but leave the app the user
    // moved to alone.
    panel?.orderOut(nil)
    interruptedApp = nil
  }
}

/// A borderless panel does not become key on its own account, and a panel that
/// cannot become key cannot be typed into.
final class FocusPanelWindow: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}
