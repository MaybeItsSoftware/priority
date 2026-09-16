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
          Button("Done") { model.completeFocusedTask() }
            .buttonStyle(.borderedProminent)
            .focusable()
          Button("Open panel") {
            model.showsFocusPanel = true
            onClose()
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
      since: session.activeTaskStartedAt, planned: TimeInterval(session.workDurationSeconds), now: now
    ).text
  }
}
