import AppKit
import SwiftUI

/// The focus panel: a floating window you leave up, summoned by a global
/// hotkey and reachable without the app being in the Dock.
///
/// It is deliberately *not* a Spotlight-style overlay. An overlay vanishes the
/// moment you click into the thing you were working on, which is the wrong
/// behaviour for a running clock — the one thing you want visible while you
/// work somewhere else. This stays where you put it, at the size you gave it,
/// until you dismiss it or quit.
///
/// Everything it can do it can do on its own: pick a task, run the block,
/// score it. Needing the main window for any of that would be what forced a
/// Dock icon back into a workflow that does not want one.
@MainActor
final class FocusPanelController: NSObject, NSWindowDelegate {
  /// The size it comes up at the first time. After that its own frame is
  /// remembered, because a window you can move and resize but which forgets is
  /// worse than one you cannot move at all.
  private static let defaultSize = NSSize(width: 420, height: 640)
  private static let minSize = NSSize(width: 340, height: 380)
  /// Where the first one lands: slightly above centre, out of the way of the
  /// menu bar, on whichever screen the pointer is on.
  private static let verticalAnchor: CGFloat = 0.14
  private static let frameAutosaveName = "PriorityFocusPanelV2"

  private var panel: FocusPanelWindow?
  private var interruptedApp: NSRunningApplication?
  /// A panel that stays up is only built once, so `onAppear` fires once. Every
  /// later summon has to say so out loud for the field to take the caret back
  /// and the last search to be cleared.
  private let summons = FocusPanelSummons()

  var isVisible: Bool { panel?.isVisible ?? false }

  func toggle(model: WorkspaceViewModel) {
    if isVisible { dismiss(.back) } else { show(model: model) }
  }

  func show(model: WorkspaceViewModel) {
    let panel = makePanelIfNeeded(model: model)
    if !NSApp.isActive { interruptedApp = NSWorkspace.shared.frontmostApplication }
    // Deliberately *not* `NSApp.activate`: activating raises every window the
    // app owns, so summoning the panel dragged the main window up with it.
    // A non-activating panel can take key on its own account, which is the
    // whole reason for that style mask.
    panel.makeKeyAndOrderFront(nil)
    summons.count += 1
    model.reloadNextUp()
    // Belt and braces. If the panel somehow did not take key — a state the
    // window server is entitled to refuse — a panel that cannot be typed into
    // is useless, so activating and raising the main window is the lesser
    // failure.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.panel === panel, panel.isVisible, !panel.isKeyWindow else { return }
      NSApp.activate(ignoringOtherApps: true)
      panel.makeKeyAndOrderFront(nil)
    }
  }

  /// Closes the panel. `.back` hands the keyboard to whatever the hotkey
  /// interrupted, which is what Escape and the hotkey itself mean. `.toWindow`
  /// does not, because the caller is about to bring Priority's own window up —
  /// restoring the other app first would only put it straight back behind.
  func dismiss(_ destination: FocusPanelDismissal) {
    panel?.orderOut(nil)
    if destination == .back, let interruptedApp,
      interruptedApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
      interruptedApp.activate()
    }
    interruptedApp = nil
  }

  // MARK: - The window

  private func makePanelIfNeeded(model: WorkspaceViewModel) -> FocusPanelWindow {
    if let panel { return panel }
    let panel = FocusPanelWindow(
      contentRect: NSRect(origin: .zero, size: Self.defaultSize),
      styleMask: [.borderless, .nonactivatingPanel, .resizable],
      backing: .buffered,
      defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.isMovableByWindowBackground = true
    panel.minSize = Self.minSize
    // The rounded background is drawn in SwiftUI, so the window itself must
    // not paint its own square one underneath it.
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    // Deliberately not `.transient`: a transient window is hidden by Mission
    // Control and by hiding the app, which is the opposite of a panel whose
    // whole job is to stay visible over other work.
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.delegate = self
    let hosting = NSHostingController(
      rootView: FocusPanelView(summons: summons, onClose: { [weak self] in self?.dismiss($0) })
        .focusEffectDisabled()
        .font(Typography.interfaceFont)
        .environment(model))
    // Without this the hosting controller sizes the *window* from the view's
    // ideal size, and this view has none — it is all `maxWidth: .infinity` —
    // so the panel collapsed to its minimum on every launch. The window owns
    // its frame here; the view fills whatever it is given.
    hosting.sizingOptions = []
    panel.contentViewController = hosting
    self.panel = panel
    // Restoring returns false the first time, which is the only time the size
    // and anchor below should get a say.
    if !panel.setFrameUsingName(Self.frameAutosaveName) {
      panel.setContentSize(Self.defaultSize)
      position(panel)
    }
    panel.setFrameAutosaveName(Self.frameAutosaveName)
    return panel
  }

  private func position(_ panel: NSPanel) {
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
      ?? NSScreen.main
    guard let frame = screen?.visibleFrame else { panel.center(); return }
    let size = panel.frame.size
    let origin = NSPoint(
      x: frame.midX - size.width / 2,
      y: frame.maxY - frame.height * Self.verticalAnchor - size.height)
    panel.setFrameOrigin(origin)
  }

  // MARK: - NSWindowDelegate

  func windowDidResignKey(_ notification: Notification) {
    guard (notification.object as? NSWindow) === panel else { return }
    // The panel stays up — that is the point of it. What lapses is the promise
    // to hand the keyboard back: the user has already gone somewhere under
    // their own steam, so a later Escape should not yank them elsewhere again.
    interruptedApp = nil
  }
}

/// Counts summons, so the panel's content can reset itself on each one.
@Observable
final class FocusPanelSummons {
  var count = 0
}

/// Where the keyboard goes when the panel closes.
enum FocusPanelDismissal {
  /// Back to whatever the hotkey interrupted.
  case back
  /// On to Priority's own window, which the caller is about to show.
  case toWindow
}

/// A borderless panel does not become key on its own account, and a panel that
/// cannot become key cannot be typed into.
final class FocusPanelWindow: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  /// Copy, paste and friends normally arrive through the Edit menu, and an
  /// accessory app has no menu bar to put one in. The panel exists precisely
  /// so Priority can stay out of the Dock, so the shortcuts are sent straight
  /// down the responder chain instead — without this, Cmd-V into the search
  /// field does nothing at all.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let character = event.charactersIgnoringModifiers?.lowercased()
    if flags == [.command, .shift], character == "z" {
      return NSApp.sendAction(Selector(("redo:")), to: nil, from: self)
    }
    guard flags == [.command], let character else {
      return super.performKeyEquivalent(with: event)
    }
    let action: Selector?
    switch character {
    case "x": action = #selector(NSText.cut(_:))
    case "c": action = #selector(NSText.copy(_:))
    case "v": action = #selector(NSText.paste(_:))
    case "a": action = #selector(NSText.selectAll(_:))
    case "z": action = Selector(("undo:"))
    default: action = nil
    }
    guard let action else { return super.performKeyEquivalent(with: event) }
    return NSApp.sendAction(action, to: nil, from: self)
  }
}
