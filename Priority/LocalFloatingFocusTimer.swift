import AppKit
import PriorityCore
import PriorityWorkspace
import SwiftUI

/// The compact companion to the desktop Focus Panel. It intentionally exposes
/// only the current task and momentum actions; planning remains in the window.
@MainActor
final class LocalFloatingFocusTimer: NSObject, NSWindowDelegate {
  private var panel: NSPanel?

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
      contentRect: NSRect(x: 0, y: 0, width: 330, height: 166),
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
      rootView: LocalFloatingFocusTimerView(onClose: { [weak self] in self?.close() })
        .focusEffectDisabled()
        .environment(model))
    self.panel = panel
    return panel
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

  var body: some View {
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
    .frame(width: 330, height: 166, alignment: .topLeading)
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
