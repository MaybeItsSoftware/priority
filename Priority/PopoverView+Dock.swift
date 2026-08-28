import AppKit
import Combine
import PriorityCore
import SwiftUI

/// The dock row along the bottom of the popover, and the drag strip it reveals.
///
/// Split into its own file for the same reason `PopoverView+TaskRow.swift` is:
/// `PopoverView.swift` is already close to the `file_length` limit in
/// `.swiftlint.yml`. The pieces are standalone `View` structs rather than
/// `@ViewBuilder` members because each needs its own `@State` (hover, drag
/// origin), and an extension can't add stored properties.
extension PopoverView {
  var dockRow: some View { PopoverDockRow() }
  var resizeStrip: some View { PopoverResizeStrip() }
}

// MARK: - Dock row

/// A narrow strip of persistent controls, present in every root view.
///
/// Sits on `panelSurface` to bracket the panel against `topBevelArea` at the
/// other end, so the content between them reads as the content.
struct PopoverDockRow: View {
  @Environment(AppCoordinator.self) private var manager
  @Environment(TaskListViewModel.self) private var taskListViewModel
  @Environment(\.shellMode) private var shellMode

  private func chromeShows(_ element: ShellChromeElement) -> Bool {
    ShellChrome.shows(element, in: shellMode)
  }

  private func themeColor(_ token: AppThemeColorToken) -> Color {
    manager.preferences.themeColor(for: token)
  }

  var body: some View {
    let chrome = manager.popoverChrome

    HStack(spacing: 2) {
      // The window has room to say why it looks stale; the panel spends every
      // point it has on tasks.
      if chromeShows(.syncStatusReadout) {
        SyncStatusReadout()
      }
      Spacer(minLength: 0)

      // Only where there is a graph to toggle. A control that does nothing in
      // five of seven views teaches you to ignore it.
      if taskListViewModel.rootTaskView == .daily {
        DockButton(
          systemName: "chart.bar",
          isActive: chrome.showsDailyChart,
          help: chrome.showsDailyChart ? "Hide the graph" : "Show the graph",
          accessibilityLabel: "Toggle the graph"
        ) {
          chrome.showsDailyChart.toggle()
        }

        // The tasks closed today, which used to be stacked under the checklist
        // unconditionally. Same shape as the graph button: this view is about
        // dailies, and what you finished in the All list is available when you
        // ask for it rather than always in the way.
        DockButton(
          systemName: "checklist",
          isActive: chrome.showsDailyCompletions,
          help: chrome.showsDailyCompletions
            ? "Hide tasks completed today"
            : "Show tasks completed today",
          accessibilityLabel: "Toggle tasks completed today"
        ) {
          chrome.showsDailyCompletions.toggle()
        }
      }

      // The list the matrix used to keep permanently open beside itself. Same
      // shape as the Daily view's toggles: a block this view can do without,
      // switched from the dock and remembered.
      if taskListViewModel.rootTaskView == .eisenhower {
        DockButton(
          systemName: "tray.full",
          isActive: chrome.showsMatrixUnplaced,
          help: chrome.showsMatrixUnplaced
            ? "Hide what's unplaced"
            : "Show what's unplaced",
          accessibilityLabel: "Toggle the unplaced list"
        ) {
          chrome.showsMatrixUnplaced.toggle()
        }
      }

      // A window has a resize corner and a title bar to drag. The strip exists
      // only because the panel has neither.
      if chromeShows(.resizeDockButton) {
        DockButton(
          systemName: "arrow.up.and.down",
          isActive: chrome.isResizeHandleVisible,
          help: chrome.isResizeHandleVisible ? "Hide the resize handle" : "Resize this view",
          accessibilityLabel: "Toggle the resize handle"
        ) {
          chrome.isResizeHandleVisible.toggle()
        }
      }

      if chromeShows(.diagnosticsDockButton) {
        DockButton(
          systemName: "stethoscope",
          isActive: chrome.showsDiagnostics,
          help: "Diagnostics",
          accessibilityLabel: "Open diagnostics"
        ) {
          chrome.showsDiagnostics = true
        }
      }

      if manager.repository.isLoading {
        ProgressView()
          .scaleEffect(0.5)
          .frame(width: 22, height: PopoverLayout.dockHeight)
          .accessibilityLabel("Refreshing")
      } else {
        DockButton(
          systemName: "arrow.clockwise",
          isActive: false,
          help: "Refresh from Checkvist",
          accessibilityLabel: "Refresh"
        ) {
          Task { await manager.fetchTopTask() }
        }
      }

      DockButton(
        systemName: "gearshape",
        isActive: false,
        help: "Preferences",
        accessibilityLabel: "Open preferences"
      ) {
        AppDelegate.shared.menuSettings()
      }
    }
    .padding(.horizontal, 6)
    .frame(height: PopoverLayout.dockHeight)
    .frame(maxWidth: .infinity)
    .background(themeColor(.panelSurface))
  }
}

/// One icon button. Unlabelled, so it carries both a tooltip and an
/// accessibility label rather than relying on the glyph to explain itself.
private struct DockButton: View {
  @Environment(AppCoordinator.self) private var manager

  let systemName: String
  let isActive: Bool
  let help: String
  let accessibilityLabel: String
  let action: () -> Void

  @State private var isHovering = false

  private func themeColor(_ token: AppThemeColorToken) -> Color {
    manager.preferences.themeColor(for: token)
  }

  var body: some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(
          isActive
            ? themeColor(.selectionForeground)
            : themeColor(isHovering ? .textSecondary : .textMuted)
        )
        // A 22×full-height target around an 11pt glyph: the icon is small
        // because the dock is narrow, but the thing you click shouldn't be.
        .frame(width: 22, height: PopoverLayout.dockHeight)
        .background(
          RoundedRectangle(cornerRadius: 4)
            .fill(isHovering ? themeColor(.selectionBackground).opacity(0.5) : Color.clear)
            .padding(.vertical, 3)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help(help)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAddTraits(isActive ? [.isSelected] : [])
  }
}

// MARK: - Resize strip

/// Drag to set this view's height; double-click to go back to sizing from
/// content.
///
/// Deliberately summoned from the dock rather than always present: a menu-bar
/// panel has no title bar and no system resize corner, so the affordance has to
/// be visible to be findable — but it only needs to be visible when you're
/// actually resizing. Each root view keeps its own height, because the Daily
/// view stacks four sections where the All view is one list.
struct PopoverResizeStrip: View {
  @Environment(AppCoordinator.self) private var manager
  @Environment(TaskListViewModel.self) private var taskListViewModel

  /// Height when the drag began. Captured once per drag: reading the live
  /// height on every frame compounds the translation and the panel runs away
  /// from the cursor.
  @State private var dragStartHeight: CGFloat?

  private func themeColor(_ token: AppThemeColorToken) -> Color {
    manager.preferences.themeColor(for: token)
  }

  var body: some View {
    let view = taskListViewModel.rootTaskView
    let isCustom = manager.popoverChrome.height(for: view) != nil

    RoundedRectangle(cornerRadius: 1.5)
      .fill(themeColor(isCustom ? .textSecondary : .textMuted).opacity(0.5))
      .frame(width: 32, height: 3)
      .frame(maxWidth: .infinity, minHeight: PopoverLayout.resizeStripHeight)
      .contentShape(Rectangle())
      .onHover { inside in
        // Says "resizes" before you commit to a drag.
        if inside {
          NSCursor.resizeUpDown.push()
        } else {
          NSCursor.pop()
        }
      }
      .gesture(
        DragGesture(minimumDistance: 1)
          .onChanged { value in
            let start = dragStartHeight ?? PopoverLayout.preferredHeight(for: manager)
            if dragStartHeight == nil { dragStartHeight = start }
            // Stored in the view's own terms — the Daily view keeps its height
            // without the chart, so the graph button adds and removes the
            // chart's height rather than resizing the checklist under it.
            manager.popoverChrome.setHeight(
              PopoverLayout.storedHeight(
                forDisplayed: start + value.translation.height, in: manager),
              for: view
            )
          }
          .onEnded { _ in dragStartHeight = nil }
      )
      .onTapGesture(count: 2) {
        manager.popoverChrome.resetHeight(for: view)
      }
      .help(
        isCustom
          ? "Drag to resize. Double-click to fit the content again."
          : "Drag to resize this view."
      )
      .accessibilityLabel("Resize this view")
      .accessibilityHint("Drag up or down to change the height. Double-tap to reset.")
  }
}

// MARK: - Sync status

/// The window's "is what I'm looking at current?" line.
///
/// Ticks on a timer rather than on data changes: the text is a statement about
/// elapsed time, so left alone it would keep claiming "just now" for an hour.
/// One minute is as fine-grained as `relativeDescription` ever gets.
struct SyncStatusReadout: View {
  @Environment(AppCoordinator.self) private var manager

  @State private var now = Date()

  private static let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

  private func themeColor(_ token: AppThemeColorToken) -> Color {
    manager.preferences.themeColor(for: token)
  }

  private var summary: SyncStatusSummary {
    let repository = manager.repository
    return SyncStatusFormatter.summary(
      isLoading: repository.isLoading,
      isNetworkReachable: repository.isNetworkReachable,
      canSyncRemotely: repository.canSyncRemotely,
      hasPendingOfflineWork: repository.hasPendingOfflineWork,
      errorMessage: repository.errorMessage,
      lastSuccessfulSyncAt: repository.lastSuccessfulSyncAt,
      now: now
    )
  }

  private var color: Color {
    switch summary.severity {
    case .ok: return themeColor(.textMuted)
    case .warning: return themeColor(.warning)
    case .problem: return themeColor(.danger)
    }
  }

  var body: some View {
    let summary = summary
    Text(summary.text)
      .font(.system(size: 10, weight: .medium))
      .foregroundColor(color)
      .lineLimit(1)
      .truncationMode(.tail)
      .padding(.leading, 4)
      .help(summary.text)
      .onReceive(Self.tick) { now = $0 }
  }
}
