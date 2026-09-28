import AppKit
import PriorityCore
import PriorityWorkspace
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
      tabStrip
      FocusRule()
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
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  private var tabStrip: some View {
    HStack(spacing: 0) {
      ForEach(WorkspaceDockTab.allCases) { tab in
        WorkspaceDockTabButton(tab: tab, isCurrent: model.rightDockTab == tab) {
          model.showRightDock(tab)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, theme.space.xs)
  }
}

/// One tab: a micro-label with a rule under it when it is the one showing.
private struct WorkspaceDockTabButton: View {
  @Environment(\.theme) private var theme
  let tab: WorkspaceDockTab
  let isCurrent: Bool
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      MicroLabel(tab.title, tint: isCurrent ? theme.ink : nil)
        .padding(.horizontal, theme.space.sm)
        .padding(.vertical, theme.space.xs)
        .overlay(alignment: .bottom) {
          Rectangle()
            .fill(isCurrent ? theme.primary : Color.clear)
            .frame(height: theme.emphasisBorder)
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .commandHelp(tab.command, note: tab.title)
    .accessibilityLabel(tab.title)
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
        // The pane names the task rather than itself, and only the task: the
        // list it is in is what the main pane's header already says.
        WorkspacePaneHeader(title: task.title)
        FocusRule()
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
        VStack(spacing: theme.space.xs) {
          MicroLabel("No task selected")
          Text("Select a task to edit its notes, plan and schedule here.")
            .font(theme.bodyFont(size: theme.type.microLabel.size))
            .foregroundStyle(theme.dim)
            .multilineTextAlignment(.center)
        }
        .padding(theme.space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
