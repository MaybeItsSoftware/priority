import AppKit
import SwiftUI
import TaktCore
import TaktWorkspace

/// Quick add's own window: the global hotkey brings up a field over whatever
/// app you are in, and Return or Escape puts it away again, leaving the main
/// window where it was — or closed, if it was.
///
/// Unlike the focus panel this one *is* Spotlight-like. It holds a thought on
/// its way to the inbox, not a clock, so clicking elsewhere drops it.
@MainActor
final class QuickCapturePanelController: NSObject, NSWindowDelegate {
  private static let width = WorkspaceTitleBarAddField.width + 48
  /// The field and, under it, the line of keys that steer it.
  private static let height: CGFloat = 84
  /// Where it lands: a little above centre, as Spotlight does.
  private static let verticalAnchor: CGFloat = 0.22

  private var panel: FocusPanelWindow?
  private var interruptedApp: NSRunningApplication?
  private weak var model: WorkspaceViewModel?

  var isVisible: Bool { panel?.isVisible ?? false }

  func show(model: WorkspaceViewModel) {
    self.model = model
    // Read before the panel is ordered front: the observation chain below
    // lives for as long as the panel is visible, so a second `show` while it
    // is up must not start a second one.
    let wasVisible = isVisible
    let panel = makePanelIfNeeded(model: model)
    if !NSApp.isActive { interruptedApp = NSWorkspace.shared.frontmostApplication }
    position(panel)
    model.beginQuickCapture()
    panel.orderFrontRegardless()
    panel.makeKey()
    // Only the panel comes forward, not the main window with it.
    NSRunningApplication.current.activate()
    panel.makeKeyAndOrderFront(nil)
    DispatchQueue.main.async { [weak panel] in
      guard let panel, panel.isVisible, !panel.isKeyWindow else { return }
      panel.makeKeyAndOrderFront(nil)
    }
    if !wasVisible { observeCapture(model: model) }
  }

  /// Puts the panel away and hands the keyboard back to whatever the hotkey
  /// interrupted.
  func dismiss() {
    guard let panel, panel.isVisible else { return }
    panel.orderOut(nil)
    if let model, model.isQuickCaptureActive { model.cancelQuickCapture() }
    if let interruptedApp, interruptedApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
      interruptedApp.activate()
    }
    interruptedApp = nil
  }

  /// Return and Escape both end the capture in the model; the panel follows.
  private func observeCapture(model: WorkspaceViewModel) {
    withObservationTracking {
      _ = model.isQuickCaptureActive
    } onChange: {
      Task { @MainActor [weak self, weak model] in
        guard let self, let model, self.isVisible else { return }
        if model.isQuickCaptureActive { self.observeCapture(model: model) } else { self.dismiss() }
      }
    }
  }

  private func makePanelIfNeeded(model: WorkspaceViewModel) -> FocusPanelWindow {
    if let panel { return panel }
    let panel = FocusPanelWindow(
      contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.isMovableByWindowBackground = true
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.delegate = self
    let hosting = NSHostingController(
      rootView: QuickCapturePanelView()
        .focusEffectDisabled()
        .themedBodyFont()
        .environment(model)
        .themed(AppDelegate.shared.checkvistManager.theme))
    hosting.sizingOptions = []
    panel.contentViewController = hosting
    self.panel = panel
    return panel
  }

  private func position(_ panel: NSPanel) {
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    guard let frame = screen?.visibleFrame else { panel.center(); return }
    panel.setFrameOrigin(NSPoint(
      x: frame.midX - Self.width / 2,
      y: frame.maxY - frame.height * Self.verticalAnchor - Self.height))
  }

  func windowDidResignKey(_ notification: Notification) {
    guard (notification.object as? NSWindow) === panel else { return }
    // Clicking away is a change of mind, as it is in Spotlight. The keyboard
    // has already gone where the user sent it, so it is not handed back.
    interruptedApp = nil
    dismiss()
  }
}

/// The field on a card of its own: a raised surface and a hairline, no more.
/// Under it, the keys the field answers (`TitleBarAddTextField`'s
/// `doCommandBy`): the arrows steer a capture somewhere no tooltip on a
/// summoned panel would ever be hovered long enough to say.
private struct QuickCapturePanelView: View {
  @Environment(\.theme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: theme.space.sm) {
      WorkspaceTitleBarAddField()
      HStack(spacing: theme.space.md) {
        KeyHint("↩", "Add")
        KeyHint("esc", "Cancel")
        KeyHint("↑ ↓", "List")
        KeyHint("← →", "Day")
      }
    }
    .padding(theme.space.md)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(
      RoundedRectangle(cornerRadius: theme.panelRadius)
        .fill(theme.raised))
    .overlay(
      RoundedRectangle(cornerRadius: theme.panelRadius)
        .strokeBorder(theme.border, lineWidth: theme.hairline))
  }
}
