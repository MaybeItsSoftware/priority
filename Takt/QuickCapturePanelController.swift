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
  /// The width of the window's own overlays — the palette, the list finder —
  /// since it is drawn as one.
  private static let width = WorkspaceOverlayMetrics.width
  /// The field, the lists it can go to, and the line of keys that steer it.
  /// The list takes whatever the other two leave.
  private static let height: CGFloat = 320
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
    // No shadow: the overlays in the window have none, and this is one of
    // them summoned over another app. The hairline is the edge.
    panel.hasShadow = false
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
    // The size is set here, every time, not only at creation: handing the
    // panel a hosting controller with no sizing options resized it to the
    // hosting view's starting frame, which is zero. The field took the
    // keyboard in a window nobody could see, so the hotkey looked dead.
    let size = NSSize(width: Self.width, height: Self.height)
    guard let frame = screen?.visibleFrame else {
      panel.setContentSize(size)
      panel.center()
      return
    }
    panel.setFrame(
      NSRect(
        origin: NSPoint(
          x: frame.midX - Self.width / 2,
          y: frame.maxY - frame.height * Self.verticalAnchor - Self.height),
        size: size),
      display: false)
  }

  func windowDidResignKey(_ notification: Notification) {
    guard (notification.object as? NSWindow) === panel else { return }
    // Clicking away is a change of mind, as it is in Spotlight. The keyboard
    // has already gone where the user sent it, so it is not handed back.
    interruptedApp = nil
    dismiss()
  }
}

/// Drawn as the window's overlays are (`WorkspaceOverlayHost`), because it
/// is one of them, summoned over another app: the raised surface and its
/// hairline at the panel radius, the field row, a rule, and under it every
/// list the capture can go to in the list finder's rows — the one it is going
/// to selected, ↑ and ↓ moving it — then the overlays' foot of keys, with the
/// day it starts at the end. All of it in the theme the window is in.
private struct QuickCapturePanelView: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme

  var body: some View {
    VStack(spacing: 0) {
      WorkspaceTitleBarAddField()
      FocusRule()
      QuickCaptureDestinationList()
        .frame(maxHeight: .infinity)
      WorkspaceOverlayFooter(
        hints: "↑↓ list · ←→ start day · ↩ add · esc cancel",
        trailing: model.quickCaptureStartLabel)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .themedSurface(theme, fill: theme.raised, radius: theme.panelRadius)
  }
}

/// Where a capture can go: every list, then the nested lists under it, in the
/// list finder's rows (`WorkspaceListNavigator`) — the list's name, where it
/// lives beside it in muted type, and the selection band on the one the
/// capture is going to. A click picks one and hands the caret back.
private struct QuickCaptureDestinationList: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme

  var body: some View {
    let destinations = model.quickCaptureDestinations
    let selectedID = model.quickCaptureDestination?.id
    let homeID = model.quickCaptureHomeList?.id
    let folderNames = Dictionary(model.folders.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    let listFolders = Dictionary(model.lists.map { ($0.id, $0.folderId) }, uniquingKeysWith: { first, _ in first })
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(destinations) { destination in
            HStack(spacing: theme.space.sm) {
              Label(
                destination.title,
                systemImage: destination.parentTaskID == nil ? "list.bullet" : "list.bullet.indent")
                .foregroundStyle(theme.ink)
                .lineLimit(1)
              if let context = context(of: destination, folderNames: folderNames, listFolders: listFolders) {
                Text(context)
                  .foregroundStyle(theme.muted)
                  .lineLimit(1)
                  .truncationMode(.middle)
              }
              Spacer(minLength: theme.space.sm)
              if destination.id == homeID {
                Text("Default").font(theme.captionFont).foregroundStyle(theme.dim)
              }
            }
            .font(theme.bodyFont())
            .overlayRow(isSelected: destination.id == selectedID)
            .id(destination.id)
            .onTapGesture {
              model.quickCaptureDestinationID = destination.id
              model.quickCaptureFocusRequest += 1
            }
          }
        }
      }
      .onAppear { if let selectedID { proxy.scrollTo(selectedID) } }
      .onChange(of: selectedID) { _, id in
        if let id { proxy.scrollTo(id) }
      }
    }
  }

  /// Where it lives, as the list finder says it: a list's folder, or the
  /// lists and nested lists a nested list sits in.
  private func context(
    of destination: QuickCaptureDestination,
    folderNames: [String: String],
    listFolders: [String: String?]
  ) -> String? {
    guard destination.parentTaskID != nil else {
      return listFolders[destination.listID]?.flatMap { folderNames[$0] }
    }
    let parents = destination.path.components(separatedBy: " › ").dropLast()
    return parents.isEmpty ? nil : parents.joined(separator: " › ")
  }
}
