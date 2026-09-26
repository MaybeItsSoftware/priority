import AppKit
import PriorityCore
import PriorityWorkspace
import SwiftUI

/// The compact companion to the desktop Focus Panel. It intentionally exposes
/// only the current task and momentum actions; planning remains in the window.
///
/// It collapses to a single row when the pointer is not on it, so what sits
/// over your other work while a block runs is a strip of task and clock rather
/// than a card of buttons. Hovering brings the buttons back, which means the
/// resting state can be small enough to leave on screen without it being in
/// the way of the thing you are supposed to be doing.
@MainActor
final class LocalFloatingFocusTimer: NSObject, NSWindowDelegate {
  private var panel: NSPanel?

  static let width: CGFloat = 330
  static let collapsedHeight: CGFloat = 40
  static let expandedHeight: CGFloat = 166

  func show(model: WorkspaceViewModel, activate: Bool = false) {
    let panel = makePanel(model: model)
    if activate {
      panel.makeKeyAndOrderFront(nil)
    } else {
      // Starting from a card should not steal keyboard focus from the board.
      panel.orderFrontRegardless()
    }
  }

  func close() {
    panel?.orderOut(nil)
  }

  private func makePanel(model: WorkspaceViewModel) -> NSPanel {
    if let panel { return panel }
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.collapsedHeight),
      styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView],
      backing: .buffered,
      defer: false)
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.delegate = self
    panel.center()
    panel.contentViewController = NSHostingController(
      rootView: LocalFloatingFocusTimerView(
        onClose: { [weak self] in self?.close() },
        onExpandedChange: { [weak self] expanded in self?.setExpanded(expanded) })
        .focusEffectDisabled()
        .environment(model))
    self.panel = panel
    setExpanded(false)
    return panel
  }

  /// Grows and shrinks the panel around its **top** edge.
  ///
  /// A window's origin is its bottom-left, so resizing it by height alone
  /// would slide the strip you are pointing at downwards and out from under
  /// the pointer — which immediately un-hovers it, collapsing it again. Held
  /// by the top edge it expands downwards and stays put.
  private func setExpanded(_ expanded: Bool) {
    guard let panel else { return }
    // The close button would sit on top of the collapsed row's text. It is
    // reachable the moment the panel is expanded, which is the moment anyone
    // reaches for it.
    panel.standardWindowButton(.closeButton)?.isHidden = !expanded
    let height = expanded ? Self.expandedHeight : Self.collapsedHeight
    var frame = panel.frame
    guard frame.height != height else { return }
    frame.origin.y += frame.height - height
    frame.size.height = height
    panel.setFrame(frame, display: true, animate: false)
  }
}

/// The companion's contents: the task, the clock, and the three things worth
/// doing to a block from the corner of a screen.
///
/// It finishes and scores a block through the summoned panel rather than the
/// main window. Sending someone back to the window to answer one question
/// undoes the reason they are looking at a 330-point clock in the first place.
private struct LocalFloatingFocusTimerView: View {
  @Environment(WorkspaceViewModel.self) private var model
  let onClose: () -> Void
  let onExpandedChange: (Bool) -> Void
  @State private var isHovering = false

  /// With no session there is nothing to collapse to — the panel is then a
  /// message and a way out, and both have to stay readable.
  private var isExpanded: Bool { isHovering || model.activeFocusSession == nil }

  var body: some View {
    Group {
      if isExpanded {
        expandedBody
      } else {
        collapsedRow
      }
    }
    .frame(
      width: LocalFloatingFocusTimer.width,
      height: isExpanded
        ? LocalFloatingFocusTimer.expandedHeight : LocalFloatingFocusTimer.collapsedHeight,
      alignment: .topLeading)
    .onHover { hovering in
      isHovering = hovering
      onExpandedChange(isExpanded)
    }
    .onChange(of: model.activeFocusSession == nil) { _, _ in
      onExpandedChange(isExpanded)
    }
  }

  /// The resting state: what is running, and how long it has been.
  private var collapsedRow: some View {
    HStack(spacing: 8) {
      if let session = model.activeFocusSession, let task = model.activeFocusTask {
        Circle()
          .fill(tint(session: session, overrun: false))
          .frame(width: 6, height: 6)
        Text(task.title)
          .font(.callout)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 6)
        TimelineView(.periodic(from: .now, by: 1)) { context in
          let reading = reading(session: session, now: context.date)
          Text(reading.text)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .monospacedDigit()
            .contentTransition(.numericText())
            .foregroundStyle(tint(session: session, overrun: reading.isOverrun))
        }
      }
    }
    .padding(.horizontal, 12)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var expandedBody: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let session = model.activeFocusSession, let task = model.activeFocusTask {
        VStack(alignment: .leading, spacing: 3) {
          if let list = model.list(for: task) { MicroLabel(list.name) }
          Text(task.title)
            .font(.headline)
            .lineLimit(2)
            .truncationMode(.tail)
            .help(task.title)
        }
        TimelineView(.periodic(from: .now, by: 1)) { context in
          let reading = reading(session: session, now: context.date)
          VStack(alignment: .leading, spacing: 6) {
            Text(reading.text)
              .font(.system(size: 30, weight: .semibold, design: .monospaced))
              .monospacedDigit()
              .contentTransition(.numericText())
              .foregroundStyle(tint(session: session, overrun: reading.isOverrun))
            hairline(session: session, now: context.date)
          }
        }
        Spacer(minLength: 0)
        HStack(spacing: 6) {
          Button("Done") { score(completeTask: true) }
            .buttonStyle(.borderedProminent)
            .focusable()
          Button(session.pausedAt == nil ? "Pause" : "Resume") { model.toggleFocusPause() }
            .buttonStyle(.bordered)
            .focusable()
          Button("Log") { score(completeTask: false) }
            .buttonStyle(.bordered)
            .focusable()
            .help("Keep the task open and log the time so far")
          Spacer(minLength: 0)
          Button {
            onClose()
            AppDelegate.shared.showMainWindow()
            model.presentFocusScreen()
          } label: {
            Image(systemName: "macwindow")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .focusable()
          .help("Open the main window on this session")
        }
      } else {
        Text("No running block").foregroundStyle(.secondary)
        Button("Close") { onClose() }
          .focusable()
      }
    }
    .padding(16)
  }

  /// The block's shape as a length rather than a second figure to read.
  private func hairline(session: FocusSession, now: Date) -> some View {
    let fraction = session.workDurationSeconds > 0
      ? Double(session.elapsedSeconds(now: now)) / Double(session.workDurationSeconds)
      : 0
    return GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.primary.opacity(0.08))
        Capsule()
          .fill(tint(session: session, overrun: fraction >= 1))
          .frame(width: max(2, proxy.size.width * min(1, fraction)))
      }
    }
    .frame(height: 3)
  }

  /// Hands the block to the panel, which can score it over whatever app is in
  /// front. The window is not involved and does not need to exist.
  private func score(completeTask: Bool) {
    model.requestFocusCompletion(completeTask: completeTask, from: .panel)
    onClose()
    AppDelegate.shared.focusPanelController.show(model: model)
  }

  private func tint(session: FocusSession, overrun: Bool) -> Color {
    if session.pausedAt != nil { return model.themeColor(.warning) }
    return overrun ? model.themeColor(.warning) : Color.accentColor
  }

  private func reading(session: FocusSession, now: Date) -> FocusTimerDisplay.Reading {
    FocusTimerDisplay.reading(
      elapsed: TimeInterval(session.elapsedSeconds(now: now)),
      planned: TimeInterval(session.workDurationSeconds))
  }
}
