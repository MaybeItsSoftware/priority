import AppKit
import TaktCore
import SwiftUI

/// The main window's title bar: the traffic lights, where you are, and the
/// modes you could be in — drawn by the app, the way an editor's is, rather
/// than by `NSToolbar`.
///
/// The window has no toolbar and a hidden, transparent title bar over
/// full-size content, so this strip is the top of the window: the theme's
/// paper across the full width, a hairline in the border role under it, and
/// the standard traffic lights moved down to sit centred in it
/// (`MainWindowTitleStripChrome`). The stock `.unifiedCompact` toolbar it
/// replaced drew the system's own material and type above a window that was
/// otherwise the theme's from edge to edge.
///
/// The strip says **which scope** the window is on — the list, folder or
/// Everything, the way Zed's names the project — and carries the mode strip.
/// The pane header below names the same scope as a switcher with the
/// chevron that opens the list finder; this one is a label, because the
/// switcher already has a home. Adding a task has its own homes too — the
/// draft row in the outline and the quick-add hotkey's window — so there is no
/// add field here.
///
/// It behaves as a title bar: dragging it anywhere but on a control moves the
/// window, and double-clicking it does what System Settings says a title bar
/// double-click does.
struct MainWindowTitleStrip: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  /// Where the strip's content may start: past the traffic lights, or the
  /// gutter alone in full screen, where the lights are not in the strip.
  @State private var lightsInset: CGFloat = 0

  var body: some View {
    let height = theme.titleStripHeight
    HStack(spacing: theme.space.md) {
      Text(model.currentBoardScopeTitle)
        .font(theme.bodyFont())
        .foregroundStyle(theme.muted)
        .lineLimit(1)
        .truncationMode(.middle)
        // A label, not a control: a press on it starts a window drag.
        .allowsHitTesting(false)
        .accessibilityAddTraits(.isHeader)
      Rectangle()
        .fill(theme.border)
        .frame(width: theme.hairline, height: theme.space.lg)
        .allowsHitTesting(false)
      WorkspaceModeStrip()
        .fixedSize()
        .layoutPriority(1)
      Spacer(minLength: 0)
    }
    .padding(.leading, max(lightsInset, theme.space.md))
    .padding(.trailing, theme.space.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: height)
    .background {
      MainWindowTitleStripChrome(height: height) { inset in
        if lightsInset != inset { lightsInset = inset }
      }
    }
    .background(theme.paper)
    .overlay(alignment: .bottom) { FocusRule() }
    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
      model.titleStripFrame = frame
    }
  }
}

/// Where you are, and the other places you could be.
///
/// A segmented strip rather than a menu: there are four of them, they are
/// mutually exclusive, and the one you are in is the thing worth seeing without
/// clicking anything. Drawn as quiet words rather than a stock segmented
/// control: the current one is ink on the hover tone inside a hairline, the
/// rest muted, with the hover tone under the pointer.
struct WorkspaceModeStrip: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme

  var body: some View {
    let onScreen = !model.showsTimelineScreen
    HStack(spacing: theme.space.xxs) {
      ForEach(WorkspaceViewMode.planningModes) { mode in
        WorkspaceModeSegment(
          title: mode.title, command: mode.command,
          isCurrent: onScreen && model.viewMode == mode
        ) {
          model.selectViewMode(mode)
          model.requestKeyboardFocus(.tasks)
        }
      }
      // Set apart by a rule: neither projects the tasks another way. Focus
      // is not a pane at all — it raises the panel — so it is never current.
      Rectangle()
        .fill(theme.border)
        .frame(width: theme.hairline, height: theme.space.lg)
        .padding(.horizontal, theme.space.xs)
      WorkspaceModeSegment(title: "Focus", command: .goFocus, isCurrent: false) {
        model.openFocusPanel()
      }
      WorkspaceModeSegment(
        title: "Timeline", command: .goTimeline,
        isCurrent: model.showsTimelineScreen
      ) {
        if model.showsTimelineScreen { model.dismissTimelineScreen() } else { model.presentTimelineScreen() }
      }
    }
  }
}

/// One word of the mode strip. A view of its own so the hover has somewhere
/// to live.
private struct WorkspaceModeSegment: View {
  @Environment(\.theme) private var theme
  let title: String
  let command: WorkspaceCommandID?
  let isCurrent: Bool
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
    Button(action: action) {
      // Words only, the way an editor's title bar names things: the strip
      // should be the quietest thing that still says where you are.
      Text(title)
        .font(theme.bodyFont())
        .foregroundStyle(isCurrent || isHovered ? theme.ink : theme.muted)
        .lineLimit(1)
        .padding(.horizontal, theme.space.sm)
        .padding(.vertical, theme.space.xxs)
        .background(isCurrent || isHovered ? theme.hover : Color.clear, in: shape)
        // The selection is a border, not elevation; the hover tone alone
        // would say "under the pointer" and "where you are" the same way.
        .overlay { shape.strokeBorder(isCurrent ? theme.border : Color.clear, lineWidth: theme.hairline) }
        .contentShape(shape)
    }
    .buttonStyle(.plain)
    .focusable(false)
    .onHover { isHovered = $0 }
    .help(command.map { WorkspaceCommandHelpText.text(for: $0, note: title) } ?? title)
    .accessibilityLabel(title)
    .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
  }
}

/// The AppKit half of the title strip: what makes an ordinary view behave
/// like a title bar.
///
/// Behind the strip's content, so every control in it is hit first and only
/// the strip's empty space and its labels reach this view. A press here drags
/// the window; a double-click performs the system's title bar action. It also
/// owns the traffic lights, which AppKit lays out for a 28pt title bar and puts
/// back there on every resize, key change and return from full screen: each
/// time, they are moved to the strip's vertical centre with as much room to
/// their left as above them.
struct MainWindowTitleStripChrome: NSViewRepresentable {
  let height: CGFloat
  /// Told the x the strip's content may start at: past the lights, or 0 in
  /// full screen, where they are not drawn in the strip.
  let onLightsInset: (CGFloat) -> Void

  func makeNSView(context: Context) -> ChromeView {
    let view = ChromeView()
    view.stripHeight = height
    view.onLightsInset = onLightsInset
    return view
  }

  func updateNSView(_ view: ChromeView, context: Context) {
    view.onLightsInset = onLightsInset
    if view.stripHeight != height {
      view.stripHeight = height
      view.placeTrafficLights()
    }
  }

  final class ChromeView: NSView {
    var stripHeight: CGFloat = 0
    var onLightsInset: ((CGFloat) -> Void)?
    private var reportedInset: CGFloat?
    private var observers: [NSObjectProtocol] = []

    deinit {
      observers.forEach(NotificationCenter.default.removeObserver)
    }

    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
      guard let window else { return }
      if event.clickCount == 2 {
        performDoubleClickAction(on: window)
      } else {
        window.performDrag(with: event)
      }
    }

    /// What System Settings → Desktop & Dock → "Double-click a window's
    /// title bar to" says: fill the screen (the default since macOS 15),
    /// zoom, minimise, or nothing. The older boolean is honoured where the
    /// newer key was never written.
    ///
    /// AppKit's own title bar does this for the top 28 points, which it still
    /// owns; the strip is taller, so below that line it is this view's job.
    /// Fill is not `zoom(_:)`: zoom asks the content for its standard frame,
    /// and a SwiftUI root answers with its minimum width.
    private func performDoubleClickAction(on window: NSWindow) {
      let defaults = UserDefaults.standard
      switch defaults.string(forKey: "AppleActionOnDoubleClick") {
      case "Minimize": window.performMiniaturize(nil)
      case "None": break
      case "Maximize", "Zoom": window.performZoom(nil)
      case "Fill": fill(window)
      default:
        if defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick") {
          window.performMiniaturize(nil)
        } else {
          fill(window)
        }
      }
    }

    /// The frame the window had before it was filled, so a second
    /// double-click puts it back, as the system's own does.
    private var frameBeforeFill: NSRect?

    private func fill(_ window: NSWindow) {
      guard let screen = window.screen ?? NSScreen.main else { return }
      let visible = screen.visibleFrame
      let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      if window.frame.integral == visible.integral, let previous = frameBeforeFill {
        frameBeforeFill = nil
        window.setFrame(previous, display: true, animate: animate)
      } else {
        frameBeforeFill = window.frame
        window.setFrame(visible, display: true, animate: animate)
      }
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      observers.forEach(NotificationCenter.default.removeObserver)
      observers = []
      guard let window else { return }
      // Each of these is a point where AppKit lays the title bar out again
      // and puts the lights back where a 28pt bar wants them.
      let names: [Notification.Name] = [
        NSWindow.didResizeNotification,
        NSWindow.didEndLiveResizeNotification,
        NSWindow.didBecomeKeyNotification,
        NSWindow.didResignKeyNotification,
        NSWindow.didEnterFullScreenNotification,
        NSWindow.didExitFullScreenNotification,
        NSWindow.willEnterFullScreenNotification,
        NSWindow.didChangeBackingPropertiesNotification,
      ]
      observers = names.map { name in
        NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.placeTrafficLights() }
        }
      }
      placeTrafficLights()
    }

    override func layout() {
      super.layout()
      placeTrafficLights()
    }

    /// Centres the three buttons in the strip. AppKit's own layout runs after
    /// some of the notifications above, so the move is made again on the next
    /// turn of the run loop as well.
    func placeTrafficLights() {
      moveTrafficLights()
      DispatchQueue.main.async { [weak self] in self?.moveTrafficLights() }
    }

    private func moveTrafficLights() {
      guard let window else { return }
      // In full screen the lights live in the menu bar's reveal strip, which
      // AppKit owns; the strip's content starts at its own gutter.
      if window.styleMask.contains(.fullScreen) {
        report(0)
        return
      }
      let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
        .compactMap { window.standardWindowButton($0) }
      guard let close = buttons.first, let titlebar = close.superview, buttons.count == 3 else { return }
      let size = close.frame.size
      let spacing = buttons[1].frame.minX - close.frame.minX
      guard spacing > 0 else { return }
      // Inside the 28pt title bar view, which the strip is taller than: from
      // the strip's top, then turned into the title bar's own coordinates.
      let top = ((stripHeight - size.height) / 2).rounded()
      let titlebarHeight = titlebar.bounds.height
      var y = titlebar.isFlipped ? top : titlebarHeight - top - size.height
      y = min(max(y, 0), max(titlebarHeight - size.height, 0))
      for (index, button) in buttons.enumerated() {
        let origin = NSPoint(x: top + CGFloat(index) * spacing, y: y)
        if button.frame.origin != origin { button.setFrameOrigin(origin) }
      }
      report(top + 2 * spacing + size.width + top)
    }

    /// Only on a change, and on the next turn: this runs inside layout, which
    /// can be inside a SwiftUI update, where the strip's state cannot change.
    private func report(_ inset: CGFloat) {
      guard inset != reportedInset else { return }
      reportedInset = inset
      DispatchQueue.main.async { [weak self] in self?.onLightsInset?(inset) }
    }
  }
}
