import PriorityCore
import PriorityWorkspace
import SwiftUI

struct LocalFocusPanel: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let onFloat: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack {
          Label("FOCUS", systemImage: "bolt.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
          Spacer()
          Text("\(FocusPoints.formatted(model.focusPoints.today)) pts today")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .help("Minutes focused, multiplied by how well each block went")
          Button("Hide") { dismiss() }
            .buttonStyle(.plain)
            .focusable()
            .keyboardShortcut(.cancelAction)
        }

        WorkspaceFocusContextControls()
        if let session = model.activeFocusSession, let task = model.activeFocusTask {
          Text(task.title)
            .font(.title2.weight(.semibold))
            .lineLimit(3)
          TimelineView(.periodic(from: .now, by: 1)) { context in
            let clock = reading(session: session, now: context.date)
            Text(clock.text)
              .font(.system(size: 42, weight: .bold, design: .monospaced))
              .foregroundStyle(clock.isOverrun ? Color.orange : Color.accentColor)
          }
          Text(session.pausedAt == nil ? "Log progress to keep working later, or complete the task." : "Paused. Only active work time is recorded.")
            .font(.callout)
            .foregroundStyle(.secondary)

          Divider()
          Text("UP NEXT").font(.caption.weight(.bold)).foregroundStyle(.secondary)
          ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 6) {
              ForEach(model.focusQueue) { queued in
                HStack {
                  Image(systemName: queued.item.state == .completed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(queued.item.state == .completed ? Color.green : Color.secondary)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(queued.task.title).lineLimit(1).truncationMode(.tail).help(queued.task.title)
                    if queued.item.state == .queued,
                      let blocked = model.blockedFocusTasks.first(where: { $0.id == queued.task.id }) {
                      Text(blocked.reasons.map { model.unavailableDescription($0) }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.orange)
                    }
                  }
                  Spacer()
                }
              }
            }
          }
          .frame(maxHeight: 110)

          HStack {
            Button("Complete task") { model.requestFocusCompletion() }.buttonStyle(.bordered)
            Button("Log progress") { model.requestFocusCompletion(completeTask: false) }
              .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            Button(session.pausedAt == nil ? "Pause" : "Resume") { model.toggleFocusPause() }
              .buttonStyle(.bordered).focusable()
            Button { onFloat() } label: { Image(systemName: "pip") }
              .buttonStyle(.bordered)
              .focusable()
          }
          Button("End session", role: .destructive) { model.finishFocus() }
            .buttonStyle(.bordered)
        } else {
          if model.activeFocusSession != nil {
            Text("Queued tasks are currently unavailable. Change conditions or available time to resume the queue.")
            ForEach(model.focusQueue.filter { $0.item.state == .queued }) { queued in
              VStack(alignment: .leading) {
                Text(queued.task.title).font(.callout)
                if let blocked = model.blockedFocusTasks.first(where: { $0.id == queued.task.id }) {
                  Text(blocked.reasons.map { model.unavailableDescription($0) }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.orange)
                } else { Text("Task is not currently executable").font(.caption).foregroundStyle(.secondary) }
              }
            }
            Button("Try queued tasks") { model.focusContextChanged() }
            Button("End session") { model.finishFocus() }
          } else { ContentUnavailableView("Focus session complete", systemImage: "checkmark.circle") }
        }
        Divider()
        // The day's shape is a mode of its own now, at pane size. Repeating a
        // squeezed copy of it here would be the second place to read the same
        // thing, and the worse one.
        Button {
          dismiss()
          model.presentTimelineScreen()
        } label: {
          Label("See the day's timeline", systemImage: "chart.bar.doc.horizontal")
            .font(.callout)
        }
        .buttonStyle(.plain)
        .focusable()
      }
      .padding(28)
    }
    .frame(width: 560, height: 660, alignment: .topLeading)
  }

  private func reading(session: FocusSession, now: Date) -> FocusTimerDisplay.Reading {
    FocusTimerDisplay.reading(
      elapsed: TimeInterval(session.elapsedSeconds(now: now)), planned: TimeInterval(session.workDurationSeconds))
  }
}
