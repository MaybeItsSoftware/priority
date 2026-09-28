import PriorityCore
import PriorityWorkspace
import SwiftUI

/// The strip along the foot of the window.
///
/// Left: the left dock's toggle, a glyph and nothing else. Middle: what is
/// happening right now — a half-typed key sequence, a message, an error.
/// Right: the running block, the day's tally, sync, and last, against the
/// right edge, the right dock's toggles — each toggle on the side of the window
/// its pane opens on. It is the Zed status bar's layout, and
/// it takes over three jobs that had no home: the toolbar's dock toggles, the
/// modal "Priority needs attention" alert, and the sequence prefix, which was
/// held silently so a pressed `d` looked like a key that did nothing.
///
/// It is the window's only strip along the bottom. The panes used to carry
/// their own — the sidebar's new-list bar, Today's, Focus's and the timeline's
/// key hints — which made the foot of the window two strips deep and stepped
/// between columns. Their buttons went to the pane headers and their hints to
/// the reference (⌘/).
struct WorkspaceStatusBar: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme

  var body: some View {
    HStack(spacing: theme.space.sm) {
      sidebarToggle
      Spacer(minLength: theme.space.sm)
      WorkspaceStatusMessage()
      Spacer(minLength: theme.space.sm)
      WorkspaceStatusTrailing()
      rightDockToggles
    }
    .padding(.horizontal, theme.space.xs)
    // One icon button and a hair of air: tall enough for a key cap, short
    // enough to be furniture. From the theme, so it tracks the header bands.
    .frame(height: theme.paneIconButtonSize + theme.space.xs)
    .frame(maxWidth: .infinity)
    // The page, like everything above it; the rule is what says "status bar".
    .background(theme.paper)
    .overlay(alignment: .top) { FocusRule() }
  }

  /// The left dock's toggle, alone. The strip used to spell out which region
  /// had the keyboard beside it in capitals; the focused row's hairline says
  /// that where you are looking, so the name moved into the tooltip.
  private var sidebarToggle: some View {
    WorkspacePaneIconButton(
      "sidebar.leading", title: "Sidebar", command: .windowToggleSidebar, isOn: model.isSidebarVisible,
      note: "Sidebar (the keyboard is in \(Self.regionTitle(model.keyboardFocusArea)); ⌃Tab moves it on)"
    ) { model.toggleSidebar() }
  }

  private var rightDockToggles: some View {
    HStack(spacing: theme.space.xxs) {
      ForEach(WorkspaceDockTab.allCases) { tab in
        let isOn = model.isRightDockVisible && model.rightDockTab == tab
        WorkspacePaneIconButton(tab.symbolName, title: tab.title, command: tab.command, isOn: isOn) {
          if isOn { model.hideRightDock() } else { model.showRightDock(tab) }
        }
      }
    }
  }

  static func regionTitle(_ area: WorkspaceFocusArea) -> String {
    switch area {
    case .sidebar: "the sidebar"
    case .tasks: "the tasks"
    case .inspector: "the inspector"
    case .done: "the done rail"
    }
  }
}

/// Hours and minutes, never seconds, for a tally: an estimate or a log
/// measured to the second is a precision nobody typed in. Shared by the status
/// bar and the Today header so the two say a duration the same way.
enum WorkspaceDurationText {
  static func short(_ seconds: Int) -> String {
    let minutes = max(0, seconds) / 60
    if minutes < 60 { return "\(minutes)m" }
    let remainder = minutes % 60
    return remainder == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(remainder)m"
  }
}

/// The middle: a pending key, else an error, else a passing message.
///
/// Its own view so the prefix — which changes on keystrokes — redraws this and
/// nothing else in the strip.
private struct WorkspaceStatusMessage: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(AppCoordinator.self) private var manager
  @Environment(\.theme) private var theme

  var body: some View {
    if !model.pendingKeyPrefix.isEmpty {
      HStack(spacing: theme.space.xs) {
        KeyCap("\(model.pendingKeyPrefix)…")
        Text("waiting for the second key")
          .font(theme.monoFont(size: theme.type.microLabel.size))
          .foregroundStyle(theme.dim)
      }
    } else if let error = model.errorMessage {
      // An error stays until it is dismissed or the next action succeeds, but
      // it no longer stops everything with an alert to say so.
      HStack(spacing: theme.space.xs) {
        Image(systemName: "exclamationmark.triangle.fill")
        Text(error)
          .lineLimit(1)
          .truncationMode(.tail)
          .help(error)
        Button {
          model.errorMessage = nil
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss")
      }
      .font(theme.captionFont)
      .foregroundStyle(theme.danger)
    } else if let message = manager.statusMessage {
      Text(message)
        .font(theme.monoFont(size: theme.type.microLabel.size))
        .foregroundStyle(theme.muted)
        .lineLimit(1)
    }
  }
}

/// The right: the running block, today's tally, and sync.
private struct WorkspaceStatusTrailing: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(AppCoordinator.self) private var manager
  @Environment(\.theme) private var theme

  /// How much of the running task's title the strip gives room to.
  static let focusTitleWidth: CGFloat = 220

  var body: some View {
    HStack(spacing: theme.space.md) {
      if let session = model.activeFocusSession, let task = model.activeFocusTask {
        runningBlock(session, task: task)
      }
      tally
      sync
    }
    .font(theme.monoFont(size: theme.type.microLabel.size))
    .foregroundStyle(theme.muted)
    .lineLimit(1)
  }

  /// The block and its clock. Click to go back to it.
  private func runningBlock(_ session: FocusSession, task: WorkspaceTask) -> some View {
    Button {
      model.presentFocusScreen()
    } label: {
      HStack(spacing: theme.space.xs) {
        Image(systemName: session.pausedAt == nil ? "timer" : "pause.fill")
          .foregroundStyle(session.pausedAt == nil ? theme.primary : theme.warning)
        Text(task.title)
          .truncationMode(.tail)
          .frame(maxWidth: Self.focusTitleWidth, alignment: .leading)
          .fixedSize(horizontal: true, vertical: false)
        TimelineView(.periodic(from: .now, by: 1)) { context in
          let reading = FocusTimerDisplay.reading(
            elapsed: TimeInterval(session.elapsedSeconds(now: context.date)),
            planned: TimeInterval(session.workDurationSeconds))
          Text(reading.isOverrun ? "+\(reading.text)" : reading.text)
            .monospacedDigit()
            .foregroundStyle(reading.isOverrun ? theme.warning : theme.ink)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .commandHelp(.goFocus, note: "Back to the running block")
  }

  /// Time logged, points earned and tasks closed today — the numbers the day
  /// is scored on elsewhere in the app, and the reason to glance down here.
  ///
  /// The week behind them is in the tooltip. Today's pane used to stack all of
  /// this in two rows of capitals above its list, and a list of the day's
  /// logged blocks below it; the tally lives here now, and a click opens the
  /// timeline, which is where the day's blocks are read properly.
  private var tally: some View {
    let progress = model.workProgress
    let points = model.focusPoints.today
    let done = progress.today.completed
    return Button {
      model.presentTimelineScreen()
    } label: {
      HStack(spacing: theme.space.xs) {
        Text("\(WorkspaceDurationText.short(progress.today.seconds)) logged")
          .foregroundStyle(progress.today.seconds > 0 ? theme.ink : theme.dim)
        Text("·").foregroundStyle(theme.dim)
        Text("\(FocusPoints.formatted(points)) pts")
          .foregroundStyle(points > 0 ? theme.ink : theme.dim)
        Text("·").foregroundStyle(theme.dim)
        Text("\(done) done")
          .foregroundStyle(done > 0 ? theme.success : theme.dim)
      }
      .monospacedDigit()
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focusable(false)
    .help(
      "Today: time focused, focus points and tasks finished. This week: "
        + "\(WorkspaceDurationText.short(progress.week.seconds)) logged, "
        + "\(WorkspaceDurationText.short(progress.averageSecondsPerDay)) a day, "
        + "\(progress.week.completed) done. Click for the timeline.")
  }

  /// The Google Tasks mirror, the one thing here that syncs. Silent until it
  /// has done something, so an app without the integration shows nothing.
  @ViewBuilder
  private var sync: some View {
    let mirror = manager.googleTasksMirror
    switch mirror.state {
    case .syncing:
      Label("Syncing", systemImage: "arrow.triangle.2.circlepath")
    case .failed(let message):
      Label("Sync failed", systemImage: "exclamationmark.icloud")
        .foregroundStyle(theme.danger)
        .help(message)
    case .idle:
      if let last = mirror.lastSyncedAt {
        Label(last.formatted(date: .omitted, time: .shortened), systemImage: "checkmark.icloud")
          .help("Google Tasks last synced")
      }
    }
  }
}
