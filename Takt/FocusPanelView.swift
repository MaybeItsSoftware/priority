import TaktCore
import TaktWorkspace
import SwiftUI

/// The summoned panel: the day, over whatever app you were in.
///
/// It is deliberately thin. The day has one presentation — `DayView` — and this
/// only supplies the panel's own chrome: a floating surface with a border and
/// a corner radius, and the dismissal the hotkey implies. What you can read and
/// do here is identical to the window's home pane, because a day that behaved
/// differently depending on where you opened it would be two days.
///
/// While a block runs it is not the day at all but a strip: the task and its
/// clock, which is all there is to look at once the work has started.
struct FocusPanelView: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let summons: FocusPanelSummons
  let onClose: (FocusPanelDismissal) -> Void

  var body: some View {
    Group {
      if summons.isCompact(for: model), let task = model.activeFocusTask,
        let session = model.activeFocusSession {
        FocusPanelStrip(
          task: task, session: session, resetToken: summons.count,
          onShowDay: { summons.showsDay = true }, onClose: onClose)
      } else {
        DayView(surface: .panel, resetToken: summons.count, onClose: onClose)
      }
    }
    .environment(model)
    // The outermost shell of its own window, so the shell radius; paper
    // and a hairline rather than a material, like every other surface.
    .themedSurface(theme, fill: theme.paper, radius: theme.shellRadius)
  }
}

/// The running block as one row: what you are doing and how long it has had.
///
/// Nothing else is drawn. The keys still reach everything a block needs —
/// Space pauses, Return finishes and asks how it went, ↓ brings the day back,
/// Esc hides — and the tooltip says so, rather than a row of hints taking up
/// the height the strip exists to give back.
private struct FocusPanelStrip: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let task: WorkspaceTask
  let session: FocusSession
  let resetToken: Int
  let onShowDay: () -> Void
  let onClose: (FocusPanelDismissal) -> Void

  @FocusState private var hasKeyboard: Bool

  var body: some View {
    HStack(spacing: theme.space.md) {
      Text(task.title)
        .font(theme.bodyFont())
        .foregroundStyle(theme.ink)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: theme.space.sm)
      TimelineView(.periodic(from: .now, by: 1)) { context in
        let reading = FocusTimerDisplay.reading(
          elapsed: TimeInterval(session.elapsedSeconds(now: context.date)),
          planned: TimeInterval(session.workDurationSeconds))
        let isPaused = session.pausedAt != nil
        Text(isPaused ? "\u{23F8} \(reading.text)" : reading.text)
          .font(theme.numeralFont(theme.scale.title, weight: .medium))
          .monospacedDigit()
          .foregroundStyle(isPaused ? theme.muted : (reading.isOverrun ? theme.warning : theme.primary))
          .contentTransition(.numericText())
      }
    }
    .padding(.horizontal, theme.space.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
    .help("Space pauses · Return finishes · ↓ shows the day · Esc hides")
    .focusable()
    .focused($hasKeyboard)
    .onKeyPress(.space) {
      model.toggleFocusPause()
      return .handled
    }
    .onKeyPress(keys: [.return], phases: .down) { press in
      if press.modifiers.contains(.command) {
        onClose(.toWindow)
        AppDelegate.shared.showMainWindow()
      } else {
        model.requestFocusCompletion(from: .panel)
      }
      return .handled
    }
    .onKeyPress(.downArrow) {
      onShowDay()
      return .handled
    }
    .onKeyPress(.escape) {
      onClose(.back)
      return .handled
    }
    .onTapGesture(count: 2) { onShowDay() }
    .onAppear { hasKeyboard = true }
    .onChange(of: resetToken) { _, _ in hasKeyboard = true }
  }
}
