import AppKit
import PriorityWorkspace
import SwiftUI

/// The compact companion to the desktop Focus Panel. It intentionally exposes
/// only the current task and momentum actions; planning remains in the window.
@MainActor
final class LocalFloatingFocusTimer: NSObject, NSWindowDelegate {
  private var panel: NSPanel?

  func show(model: WorkspaceViewModel) {
    let panel = makePanel(model: model)
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
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
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text(remainingTime(session: session, now: context.date))
            .font(.system(size: 28, weight: .bold, design: .monospaced))
        }
        HStack {
          Button("Done") { model.completeFocusedTask() }
            .buttonStyle(.borderedProminent)
          Button("Open panel") {
            model.showsFocusPanel = true
            onClose()
          }
          .buttonStyle(.bordered)
          Spacer()
          Button("End") {
            model.finishFocus()
            onClose()
          }
          .buttonStyle(.plain)
          .foregroundStyle(.red)
        }
      } else {
        Text("No active focus session").foregroundStyle(.secondary)
        Button("Close") { onClose() }
      }
    }
    .padding(16)
    .frame(width: 330, height: 166, alignment: .topLeading)
  }

  private func remainingTime(session: FocusSession, now: Date) -> String {
    let elapsed = max(0, now.timeIntervalSince(session.startedAt))
    let seconds = max(0, session.workDurationSeconds - Int(elapsed))
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
  }
}
