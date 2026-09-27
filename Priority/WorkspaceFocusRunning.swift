import PriorityCore
import PriorityWorkspace
import SwiftUI

/// The running half of the focus pane: one task, one clock, and the four
/// things you can do to it.
///
/// It used to be a 560×660 sheet floating over the board. A sheet was the
/// wrong shape for it twice over — it left the workspace visible round the
/// edges, which is the one thing focus exists to stop, and it fixed the
/// surface at dialog size so the task title, the clock and the queue were all
/// competing for the same small box. Here it is the pane, so the clock can be
/// the size the clock deserves.
struct WorkspaceFocusRunning: View {
  @Environment(\.theme) private var theme
  @Environment(WorkspaceViewModel.self) private var model
  let session: FocusSession
  let task: WorkspaceTask

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 0)
      VStack(spacing: 22) {
        taskLine
        clock
        progress
        actions
      }
      .frame(maxWidth: 560)
      .padding(.horizontal, 32)
      Spacer(minLength: 0)
      if !queue.isEmpty {
        FocusRule()
        upNext
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - The task and the clock

  private var taskLine: some View {
    VStack(spacing: 8) {
      if let list = model.list(for: task) {
        MicroLabel(list.name)
      }
      Text(task.title)
        .font(.system(size: 30, weight: .semibold))
        .multilineTextAlignment(.center)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// Set in one size and one weight whatever it says, because a clock that
  /// changes width as the digits change is a clock you keep re-reading.
  private var clock: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let reading = reading(now: context.date)
      VStack(spacing: 6) {
        Text(reading.text)
          .font(.system(size: 76, weight: .semibold, design: .monospaced))
          .monospacedDigit()
          .foregroundStyle(clockTint(overrun: reading.isOverrun))
          .contentTransition(.numericText())
        MicroLabel(
          session.pausedAt == nil
            ? (reading.isOverrun ? "over the block" : "of \(plannedMinutes)m")
            : "paused",
          tint: session.pausedAt == nil ? nil : model.themeColor(.warning))
      }
    }
  }

  /// A hairline rather than a bar with a track: the block's shape at a glance,
  /// without a second rounded rectangle on a screen that already has one job.
  private var progress: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let fraction = fraction(now: context.date)
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule().fill(Color.primary.opacity(0.08))
          Capsule()
            .fill(clockTint(overrun: fraction >= 1))
            .frame(width: max(2, proxy.size.width * min(1, fraction)))
        }
      }
      .frame(height: 3)
    }
    .frame(height: 3)
  }

  // MARK: - Actions

  /// Done first and prominent. Everything else on this screen is a way of not
  /// finishing, so it gets the weight and the Return key.
  private var actions: some View {
    VStack(spacing: 12) {
      HStack(spacing: 8) {
        action("Done", systemImage: "checkmark", key: "↵", prominent: true) {
          model.requestFocusCompletion()
        }
        action(
          session.pausedAt == nil ? "Pause" : "Resume",
          systemImage: session.pausedAt == nil ? "pause.fill" : "play.fill", key: "P"
        ) {
          model.toggleFocusPause()
        }
        action("Log progress", systemImage: "clock.arrow.circlepath", key: "L") {
          model.requestFocusCompletion(completeTask: false)
        }
        action("Float", systemImage: "pip", key: "F") { model.requestFocusFloat() }
      }
      HStack(spacing: 14) {
        Text(
          session.pausedAt == nil
            ? "Log progress keeps the task open. Only active time is recorded."
            : "Paused. Only active work time is recorded.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
        Button("End session") { model.finishFocus() }
          .buttonStyle(.plain)
          .font(.caption)
          .foregroundStyle(.secondary)
          .focusable()
      }
    }
  }

  @ViewBuilder
  private func action(
    _ title: String, systemImage: String, key: String, prominent: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    let label = HStack(spacing: 6) {
      Image(systemName: systemImage)
      Text(title)
      Text(key)
        .font(.system(size: 10, design: .monospaced))
        .opacity(0.65)
    }
    if prominent {
      Button(action: action) { label }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .focusable()
    } else {
      Button(action: action) { label }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .focusable()
    }
  }

  // MARK: - What follows this

  private var queue: [FocusQueueTask] {
    model.focusQueue.filter { $0.task.id != task.id && $0.item.state != .completed }
  }

  private var upNext: some View {
    VStack(alignment: .leading, spacing: 8) {
      MicroLabel("Up next")
      ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(queue) { queued in
            HStack(spacing: 8) {
              Image(systemName: "circle")
                .font(.caption2)
                .foregroundStyle(.tertiary)
              Text(queued.task.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(queued.task.title)
              if let blocked = model.blockedFocusTasks.first(where: { $0.id == queued.task.id }) {
                Text(blocked.reasons.map { model.unavailableDescription($0) }.joined(separator: " · "))
                  .font(.caption2)
                  .foregroundStyle(model.themeColor(.warning))
                  .lineLimit(1)
              }
              Spacer(minLength: 0)
            }
            .font(.callout)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 96)
    }
    .focusSurfaceGutter()
    .padding(.vertical, 14)
  }

  // MARK: - Readings

  private func reading(now: Date) -> FocusTimerDisplay.Reading {
    FocusTimerDisplay.reading(
      elapsed: TimeInterval(session.elapsedSeconds(now: now)),
      planned: TimeInterval(session.workDurationSeconds))
  }

  private func fraction(now: Date) -> Double {
    guard session.workDurationSeconds > 0 else { return 0 }
    return Double(session.elapsedSeconds(now: now)) / Double(session.workDurationSeconds)
  }

  private var plannedMinutes: String {
    FocusPoints.formatted(Double(session.workDurationSeconds) / 60)
  }

  private func clockTint(overrun: Bool) -> Color {
    if session.pausedAt != nil { return .secondary }
    return overrun ? theme.warning : theme.primary
  }
}
