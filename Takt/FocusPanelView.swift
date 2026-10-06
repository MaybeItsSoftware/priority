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

  private var hasRunningBlock: Bool {
    model.pendingFocusCompletion == nil && model.activeFocusSession?.phase == .running
  }

  var body: some View {
    Group {
      if summons.isCompact(for: model), let task = model.activeFocusTask,
        let session = model.activeFocusSession {
        FocusPanelStrip(
          task: task, session: session, resetToken: summons.count,
          onShowDay: { summons.showsDay = true }, onClose: onClose)
      } else {
        DayView(
          surface: .panel, resetToken: summons.count, onClose: onClose,
          onMinimise: hasRunningBlock ? { summons.showsDay = false } : nil)
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
/// Nothing else is drawn until the pointer is over it. The keys reach
/// everything a block needs — Space finishes and asks how it went, Return
/// opens the day to add a task, P pauses, ↓ brings the day back, Esc hides —
/// and hovering shows the same actions as buttons beside the clock, so a
/// mouse is not left with only a tooltip. They take no height of their own:
/// the strip stays the size it exists to be.
private struct FocusPanelStrip: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let task: WorkspaceTask
  let session: FocusSession
  let resetToken: Int
  let onShowDay: () -> Void
  let onClose: (FocusPanelDismissal) -> Void

  @FocusState private var hasKeyboard: Bool
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: theme.space.md) {
      Text(task.title)
        .font(theme.bodyFont())
        .foregroundStyle(theme.ink)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: theme.space.sm)
      if isHovered {
        actions
          .transition(.opacity)
      }
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
    .help("Space finishes · Return adds a task · P pauses · ↓ shows the day · Esc hides")
    .focusable()
    .focused($hasKeyboard)
    // The same two keys as everywhere else: Space completes the task, which
    // here means finishing the block; Return adds one, from the day's field.
    .onKeyPress(.space) {
      model.requestFocusCompletion(from: .panel)
      return .handled
    }
    .onKeyPress(characters: ["p"]) { _ in
      model.toggleFocusPause()
      return .handled
    }
    .onKeyPress(keys: [.return], phases: .down) { press in
      if press.modifiers.contains(.command) {
        onClose(.toWindow)
        AppDelegate.shared.showMainWindow()
      } else {
        onShowDay()
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
    .onHover { hovering in withAnimation(WorkspaceMotion.quick) { isHovered = hovering } }
    .onAppear { hasKeyboard = true }
    .onChange(of: resetToken) { _, _ in hasKeyboard = true }
  }

  private var isPaused: Bool { session.pausedAt != nil }

  /// The strip's keys as buttons, in the order they matter while working.
  private var actions: some View {
    HStack(spacing: theme.space.xs) {
      stripButton(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill", key: "P") {
        model.toggleFocusPause()
      }
      stripButton("Finish", systemImage: "checkmark", key: "Space") {
        model.requestFocusCompletion(from: .panel)
      }
      stripButton("Show the day", systemImage: "list.bullet", key: "↓") { onShowDay() }
      stripButton("Open in the window", systemImage: "macwindow", key: "⌘↩") {
        onClose(.toWindow)
        AppDelegate.shared.showMainWindow()
      }
      stripButton("Hide", systemImage: "xmark", key: "Esc") { onClose(.back) }
    }
  }

  private func stripButton(
    _ title: String, systemImage: String, key: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(theme.muted)
    .help("\(title) (\(key))")
    .accessibilityLabel(title)
  }
}
