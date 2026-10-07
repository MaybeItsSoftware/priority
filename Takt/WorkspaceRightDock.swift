import AppKit
import TaktCore
import TaktWorkspace
import SwiftUI

/// The right dock: the inspector and the done rail as tabs of one column.
///
/// See `WorkspaceViewModel+Dock.swift` for why it is one dock rather than two
/// columns, and why it no longer closes itself on navigation.
struct WorkspaceRightDock: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  var focusedArea: FocusState<WorkspaceFocusArea?>.Binding

  var body: some View {
    VStack(spacing: 0) {
      tabBar
      switch model.rightDockTab {
      case .inspector:
        WorkspaceInspectorPane(focusedArea: focusedArea)
      case .done:
        WorkspaceDoneRail()
          // Claimed the way the sidebar claims its own area: a
          // `requestedFocusArea` no view answers to is handed straight back,
          // so the rail would take the keyboard and lose it again on the next
          // layout pass.
          .focusable()
          .focusEffectDisabled()
          .focused(focusedArea, equals: .done)
      case .timeline:
        WorkspaceTimelineScreen(inDock: true)
          .focusable()
          .focusEffectDisabled()
          .focused(focusedArea, equals: .timeline)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  /// An editor's tab bar: the tabs as plain titles on the left, the showing one
  /// in ink with a rule under it, and the dock's own actions as glyphs on the
  /// right. On the shared header band, so its rule meets the sidebar's and the
  /// main pane's in one line.
  private var tabBar: some View {
    WorkspaceHeaderBand(inset: 0) {
      HStack(spacing: 0) {
        ForEach(WorkspaceDockTab.allCases) { tab in
          WorkspaceDockTabButton(title: tab.title, command: tab.command, isCurrent: model.rightDockTab == tab) {
            model.showRightDock(tab)
          }
        }
      }
      Spacer(minLength: theme.space.xs)
      if model.rightDockTab == .done {
        WorkspaceDoneSummary()
      }
      WorkspacePaneIconButton("xmark", title: "Close the dock", command: model.rightDockTab.command) {
        model.hideRightDock()
      }
      .padding(.trailing, theme.space.xs)
    }
  }
}

/// One tab: its title in plain text, ink with a rule along the band's foot
/// while it is the one showing, muted otherwise. The rule is the band's own
/// height, so it sits on the header hairline rather than above it. Shared by
/// both docks' tab bars.
struct WorkspaceDockTabButton: View {
  @Environment(\.theme) private var theme
  let title: String
  let command: WorkspaceCommandID
  let isCurrent: Bool
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      Text(title)
        .font(theme.captionFont)
        .foregroundStyle(isCurrent ? theme.ink : theme.muted)
        .lineLimit(1)
        .padding(.horizontal, theme.space.md)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) {
          Rectangle()
            .fill(isCurrent ? theme.ink : Color.clear)
            .frame(height: theme.hairline)
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focusable(false)
    .commandHelp(command, note: title)
    .accessibilityLabel(title)
    .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
  }
}

/// The inspector tab. It is the one pane that has to redraw when the selection
/// moves, since it shows the selection, so it reads it here rather than making
/// the window read it.
struct WorkspaceInspectorPane: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  var focusedArea: FocusState<WorkspaceFocusArea?>.Binding

  var body: some View {
    let selected = model.selectedTask
    VStack(alignment: .leading, spacing: 0) {
      if let task = selected {
        // No band of its own under the dock's tab bar: the editor opens on the
        // task's title field, and a header saying the same title above it was
        // a second rule and a second copy of one line.
        //
        // The editor is about twenty-five controls tall; on anything short of
        // a full-height window the last of them would be off the bottom.
        ScrollView {
          VStack(alignment: .leading, spacing: theme.space.md) {
            LocalTaskInspector(
              task: task,
              focusRequest: model.focusRequest,
              requestedFocusArea: model.requestedFocusArea)
              .environment(model)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .focusSurfaceGutter()
          .padding(.vertical, theme.space.md)
        }
      } else {
        // Said rather than vanished. The pane going away when nothing was
        // selected is how it used to close itself behind your back.
        WorkspaceEmptyMessage("Select a task to edit its notes, plan and schedule here.")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(theme.paper)
    .focusable()
    .focused(focusedArea, equals: .inspector)
    .focusEffectDisabled()
    .simultaneousGesture(TapGesture().onEnded { model.reportKeyboardFocus(.inspector) })
  }
}

/// A one-point rule with an eight-point grab area either side of it: the
/// visible line stays a hairline while the target stays something you can
/// actually hit. Shared by the sidebar and the right dock.
struct WorkspaceResizeHandle: View {
  /// Which way dragging makes the pane wider: the sidebar grows to the right
  /// of its handle, the dock to the left of its own.
  enum Growth { case leading, trailing }

  @Environment(\.theme) private var theme
  @Binding var width: CGFloat
  let grows: Growth
  let range: ClosedRange<CGFloat>
  /// The width the current drag started from, so the gesture measures a
  /// translation rather than accumulating deltas.
  @State private var dragStartWidth: CGFloat?

  var body: some View {
    Rectangle()
      .fill(theme.border)
      .frame(width: theme.hairline)
      .overlay(
        Rectangle()
          .fill(Color.clear)
          .frame(width: theme.space.sm + theme.hairline)
          .contentShape(Rectangle())
          .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
          }
          .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
              .onChanged { value in
                let base = dragStartWidth ?? width
                if dragStartWidth == nil { dragStartWidth = base }
                let delta = grows == .trailing ? value.translation.width : -value.translation.width
                width = min(max(base + delta, range.lowerBound), range.upperBound)
              }
              .onEnded { _ in dragStartWidth = nil }
          )
      )
  }
}
