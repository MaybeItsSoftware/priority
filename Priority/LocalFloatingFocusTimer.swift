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

private struct LocalFloatingFocusTimerView: View {
  @Environment(WorkspaceViewModel.self) private var model
  let onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let session = model.activeFocusSession, let task = model.activeFocusTask {
        Text(task.title)
          .font(.headline)
          .lineLimit(2)
          .truncationMode(.tail)
          .help(task.title)
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text(remainingTime(session: session, now: context.date))
            .font(.system(size: 28, weight: .bold, design: .monospaced))
        }
        HStack {
          Button("Progress") {
            // The prompt lives in the window, so that there is one of it. A
            // block worth scoring is worth looking up from the corner for.
            model.requestFocusCompletion(completeTask: false)
            onClose()
            AppDelegate.shared.showMainWindow()
          }
            .buttonStyle(.borderedProminent)
            .focusable()
          Button(session.pausedAt == nil ? "Pause" : "Resume") { model.toggleFocusPause() }
          Button("Open") {
            onClose()
            AppDelegate.shared.showMainWindow()
            model.presentFocusScreen()
          }
          .buttonStyle(.bordered)
          .focusable()
          Spacer()
          Button("End") {
            model.finishFocus()
            onClose()
          }
          .buttonStyle(.plain)
          .focusable()
          .foregroundStyle(.red)
        }
      } else {
        Text("No active focus session").foregroundStyle(.secondary)
        Button("Close") { onClose() }
          .focusable()
      }
    }
    .padding(16)
    .frame(width: 330, height: 166, alignment: .topLeading)
  }

  private func remainingTime(session: FocusSession, now: Date) -> String {
    FocusTimerDisplay.reading(
      elapsed: TimeInterval(session.elapsedSeconds(now: now)), planned: TimeInterval(session.workDurationSeconds)
    ).text
  }
}
