import PriorityCore
import PriorityWorkspace
import SwiftUI

/// The strip along the foot of the window.
///
/// Left: the left dock's toggle and where the keyboard is. Middle: what is
/// happening right now — a half-typed key sequence, a message, an error.
/// Right: the running block, the day's points, sync, and last, against the
/// right edge, the right dock's tabs — each toggle on the side of the window
/// its pane opens on. It is the Zed status bar's layout, and
/// it takes over three jobs that had no home: the toolbar's dock toggles, the
/// modal "Priority needs attention" alert, and the sequence prefix, which was
/// held silently so a pressed `d` looked like a key that did nothing.
struct WorkspaceStatusBar: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme

  /// Tall enough for a key cap, short enough to be furniture.
  static let height: CGFloat = 24

  var body: some View {
    HStack(spacing: theme.space.sm) {
      leading
      Spacer(minLength: theme.space.sm)
      WorkspaceStatusMessage()
      Spacer(minLength: theme.space.sm)
      WorkspaceStatusTrailing()
      rightDockToggles
    }
    .padding(.horizontal, theme.space.sm)
    .frame(height: Self.height)
    .frame(maxWidth: .infinity)
    // The page, like everything above it; the rule is what says "status bar".
    .background(theme.paper)
    .overlay(alignment: .top) { FocusRule() }
  }

  private var leading: some View {
    HStack(spacing: theme.space.xxs) {
      WorkspaceStatusToggle(
        symbol: "sidebar.leading", title: "Sidebar", command: .windowToggleSidebar,
        isOn: model.isSidebarVisible
      ) { model.toggleSidebar() }
      Rectangle()
        .fill(theme.border)
        .frame(width: theme.hairline, height: theme.space.md)
        .padding(.horizontal, theme.space.xs)
      MicroLabel(Self.regionTitle(model.keyboardFocusArea))
        .help("Where the keyboard is. ⌃Tab moves it on.")
    }
  }

  private var rightDockToggles: some View {
    HStack(spacing: theme.space.xxs) {
      ForEach(WorkspaceDockTab.allCases) { tab in
        WorkspaceStatusToggle(
          symbol: tab.symbolName, title: tab.title, command: tab.command,
          isOn: model.isRightDockVisible && model.rightDockTab == tab
        ) {
          if model.isRightDockVisible && model.rightDockTab == tab {
            model.hideRightDock()
          } else {
            model.showRightDock(tab)
          }
        }
      }
    }
  }

  static func regionTitle(_ area: WorkspaceFocusArea) -> String {
    switch area {
    case .sidebar: "Sidebar"
    case .tasks: "Tasks"
    case .inspector: "Inspector"
    case .done: "Done"
    }
  }
}

/// A dock toggle: a glyph, lit while its pane is showing.
private struct WorkspaceStatusToggle: View {
  @Environment(\.theme) private var theme
  let symbol: String
  let title: String
  let command: WorkspaceCommandID
  let isOn: Bool
  let toggle: () -> Void

  var body: some View {
    Button(action: toggle) {
      Image(systemName: symbol)
        .font(theme.captionFont)
        .foregroundStyle(isOn ? theme.primary : theme.muted)
        .padding(.horizontal, theme.space.xs)
        .padding(.vertical, theme.space.xxs)
        .workspaceSelection(isSelected: isOn, hasKeyboard: false)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .commandHelp(command, note: title)
    .accessibilityLabel(title)
    .accessibilityAddTraits(isOn ? [.isSelected] : [])
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

  /// Points earned and tasks closed today — the two numbers the day is scored
  /// on elsewhere in the app, and the reason to glance down here.
  private var tally: some View {
    let points = model.focusPoints.today
    let done = model.workProgress.today.completed
    return HStack(spacing: theme.space.xs) {
      Text("\(FocusPoints.formatted(points)) pts")
        .foregroundStyle(points > 0 ? theme.ink : theme.dim)
      Text("·").foregroundStyle(theme.dim)
      Text("\(done) done")
        .foregroundStyle(done > 0 ? theme.success : theme.dim)
    }
    .monospacedDigit()
    .help("Focus points and tasks finished today")
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
