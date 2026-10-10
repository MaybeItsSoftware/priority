import AppKit
import Foundation
import Observation
import TaktCore
import TaktWorkspace
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceDesktopView: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(AppCoordinator.self) private var manager
  @Environment(\.theme) private var theme
  @FocusState private var focusedArea: WorkspaceFocusArea?

  var body: some View {
    VStack(spacing: 0) {
      // The window's title bar, drawn here rather than by a toolbar: the
      // window's content runs under its hidden title bar to the top edge.
      MainWindowTitleStrip()
      VStack(spacing: 0) {
        workspace
        // Across the whole window, under every column: the one strip that says
        // where the keyboard is and what is running.
        WorkspaceStatusBar()
      }
      // Over every pane but under the title strip, which stays a title bar
      // while an overlay is up. A click outside the panel is caught by the
      // window's mouse monitor.
      .overlay(alignment: .top) { WorkspaceOverlayHost() }
      // The focus clock's housekeeping is not here: the model runs it from
      // `startFocusMonitor()`, because starting a block closes this window.
    }
    .ignoresSafeArea(.container, edges: .top)
  }

  private var workspaceLayout: some View {
    // Three columns with explicit, persisted widths and a handle each, rather
    // than an `HSplitView`.
    //
    // Inside a split view the sidebar was a resizable pane like any other, so
    // it was handed a share of any width the window had spare — on a wide
    // display it opened at 367pt having been asked for 185, and once that
    // width was remembered it ratcheted wider every launch. The right-hand
    // panes had the same problem the other way: on a window with nothing
    // spare they were laid out at no width at all. An explicit width changes
    // only when you drag it.
    HStack(spacing: 0) {
      // The sidebar stays through the timeline: reading a day back often means
      // looking at which list something came from, and losing your place in the
      // workspace to do that is its own distraction.
      if model.isSidebarVisible {
        WorkspaceLeftDock(focusedArea: $focusedArea)
          .focusSection()
          .frame(width: model.sidebarWidth)
        WorkspaceResizeHandle(
          width: Bindable(model).sidebarWidth, grows: .trailing,
          range: WorkspaceViewModel.minSidebarWidth...WorkspaceViewModel.maxSidebarWidth)
      }
      // The bottom dock spans the main pane only, as Zed's does by default:
      // the side docks run the window's full height beside it.
      VStack(spacing: 0) {
        mainPane
        if model.isBottomDockVisible {
          WorkspaceHeightHandle(
            height: Bindable(model).bottomDockHeight,
            range: WorkspaceViewModel.minBottomDockHeight...WorkspaceViewModel.maxBottomDockHeight)
          WorkspaceProgressDock()
            .frame(height: model.bottomDockHeight)
        }
      }
      if model.isRightDockVisible {
        WorkspaceResizeHandle(
          width: Bindable(model).rightDockWidth, grows: .leading,
          range: WorkspaceViewModel.minRightDockWidth...WorkspaceViewModel.maxRightDockWidth)
        WorkspaceRightDock(focusedArea: $focusedArea)
          .focusSection()
          .frame(width: model.rightDockWidth)
      }
    }
    .frame(minWidth: 760, minHeight: 520)
    // One flat surface under every column. The panes are told apart by the
    // hairline in each resize handle, not by a tint of their own — a tinted
    // sidebar was a second surface the selection wash had to be tuned against.
    .background(theme.paper)
    .onAppear {
      if model.requestedFocusArea != .tasks || (model.viewMode != .board && model.viewMode != .outline) {
        focusedArea = model.requestedFocusArea
      }
    }
    .onChange(of: model.focusRequest) { _, _ in
      if model.requestedFocusArea != .tasks || (model.viewMode != .board && model.viewMode != .outline) {
        focusedArea = model.requestedFocusArea
      }
    }
    .onChange(of: focusedArea) { _, area in
      model.reportKeyboardFocus(area)
    }
  }

  private var mainPane: some View {
    // The work. The timeline used to take this pane over; it is a tab of
    // the right dock now, read beside the list rather than instead of it.
    Group {
      taskPane
        .safeAreaInset(edge: .bottom, spacing: 0) { WorkspaceTaskDeletionInset() }
        .background { WorkspaceDeletionCanceller() }
    }
    // Switching outline, board, matrix or Today fades rather than cuts. Only
    // the swap is animated: the pane's own reloads stay instant.
    .animation(WorkspaceMotion.quick, value: model.viewMode)
    .focusSection()
    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
  }

  private var workspaceAlerts: some View {
    workspaceLayout
    .alert("Start this task anyway?", isPresented: Binding(
      get: { model.focusStartOverride != nil }, set: { if !$0 { model.focusStartOverride = nil } }
    ), presenting: model.focusStartOverride) { request in
      Button("Start anyway") { model.startFocus(on: request.task, plannedSeconds: request.plannedSeconds, override: true); model.focusStartOverride = nil }
      Button("Cancel", role: .cancel) { model.focusStartOverride = nil }
    } message: { request in Text(request.explanation) }
    // A sheet rather than an overlay on purpose. A finished block's clock is
    // held open until it is scored, and an overlay goes away on any click
    // outside it — which here would throw a block's judgement away by accident.
    .sheet(item: Binding(
      get: { model.windowFocusCompletion },
      set: { if $0 == nil { model.cancelFocusCompletion() } }
    )) { pending in
      WorkspaceFocusQualityPrompt(pending: pending)
        .environment(model)
    }
  }

  private var workspace: some View {
    workspaceAlerts
    // Diagnostics needs a titled window to attach a sheet to, and this is the
    // only one the app has. `CommandExecutor` and the Workspace menu have always
    // said it was a sheet on the main window and opened that window first to get
    // one — but nothing here presented it, so both set the flag and showed you
    // the workspace. The popover was the only surface that ever put it on screen.
    //
    // It stays a sheet rather than an overlay: it is a report as tall as the
    // window, with Copy and Export buttons, read and then put away — not
    // something you pass through on the way to the next keystroke.
    .sheet(isPresented: Bindable(manager).showsDiagnostics) {
      DiagnosticsView()
        .environment(manager)
        .frame(minWidth: 620, minHeight: 520)
    }
    // A multi-field form — name, colour, icon, folder, visible root — edited
    // with the mouse as often as not. Converting it is a redesign, not a move.
    .sheet(item: Bindable(model).sidebarEditor) { editor in
      WorkspaceSidebarEditorSheet(editor: editor)
        .environment(model)
    }
    .confirmationDialog(
      model.pendingSidebarDeletion?.deletionTitle ?? "Delete item?",
      isPresented: Binding(
        get: { model.pendingSidebarDeletion != nil },
        set: { if !$0 { model.pendingSidebarDeletion = nil } }
      ),
      presenting: model.pendingSidebarDeletion
    ) { _ in
      // Return confirms, as it does for a task: the key that asked to delete
      // is already under your hand, and Esc is still there to back out.
      Button("Delete", role: .destructive) { model.confirmPendingSidebarDeletion() }
        .keyboardShortcut(.defaultAction)
      Button("Cancel", role: .cancel) {}
    } message: { item in
      Text(item.deletionMessage)
    }
  }

  @ViewBuilder
  private var taskPane: some View {
    switch model.viewMode {
    case .today:
      // The same view the hotkey summons over other apps. One component, two
      // mounts: the day cannot read differently depending on where you open it.
      DayView(surface: .window, resetToken: model.dayPresentationCount)
        .environment(model)
        .background(theme.paper)
        // The tasks region, claimed the way the matrix claims it. The day
        // used to hold the keyboard in a search field of its own; without one
        // the list is what the catalogue's keys act on.
        .focusable()
        .focused($focusedArea, equals: .tasks)
        .focusEffectDisabled()
    case .board:
      WorkspaceKanbanBoard()
        .environment(model)
    case .outline:
      WorkspaceOutlinePane()
    case .matrix:
      WorkspaceMatrixDashboard()
        .environment(model)
        .focusable()
        .focused($focusedArea, equals: .tasks)
        .focusEffectDisabled()
    }
  }
}

/// The delete prompt under the task pane.
///
/// A leaf rather than part of the shell: resolving the pending task reads the
/// model's task cache, and a read in the shell's body would redraw the whole
/// window on every refresh.
private struct WorkspaceTaskDeletionInset: View {
  @Environment(WorkspaceViewModel.self) private var model

  var body: some View {
    if model.pendingTaskDeletionID != nil, let pending = model.pendingTaskDeletion {
      TaskDeletionPrompt(task: pending)
    }
  }
}

/// A delete asked about one task is not a delete of whichever task the cursor
/// moves to, so moving lets the question go.
///
/// A leaf of its own because `onChange(of:)` reads the value in the body it
/// is attached to: on the shell, every arrow key re-ran the whole window's body.
private struct WorkspaceDeletionCanceller: View {
  @Environment(WorkspaceViewModel.self) private var model

  var body: some View {
    Color.clear
      .onChange(of: model.selectedTaskID) { _, _ in model.cancelPendingTaskDeletion() }
  }
}

struct WorkspaceItemActions: View {
  @Environment(WorkspaceViewModel.self) private var model
  let task: WorkspaceTask

  var body: some View {
    Button(task.isList ? "Open list" : "Open subtasks") { model.openItemList(task) }
    // The menu draws each item's chorded key from the catalogue. Those keys act
    // on the selected task; in here they act on the row that was clicked.
    Button("Rename…") { model.presentOverlay(.quickEdit(WorkspaceTaskQuickEditRequest(task: task, kind: .title))) }
      .commandShortcut(.taskRename)
    Button(task.isList ? "Convert to task" : "Convert to list") { model.convertItem(task) }
      .commandShortcut(.taskConvertToList)
    Button("Move to list or folder…") { model.requestMove(task) }
      .commandShortcut(.taskMove)
    Button("New nested list…") { model.requestNestedListCreation(under: task) }
    if task.isList {
      Button("Move to top level") { model.moveDroppedItem(task.id, toFolderID: nil) }
      Button(task.isPromoted == true ? "Unpin from sidebar" : "Promote to sidebar") { model.toggleListPromotion(task) }
        .commandShortcut(.taskPromoteList)
      Menu("Choose icon") {
        ForEach(WorkspaceViewModel.availableListIcons, id: \.symbol) { icon in
          Button { model.setNestedListIcon(icon.symbol, for: task) } label: { Label(icon.label, systemImage: icon.symbol) }
        }
      }
      Divider()
      Button(task.status == .open ? "Complete list" : "Reopen list") { model.toggleTask(task) }
      Button("Archive list") { model.archiveNestedList(task) }
    }
  }
}

/// A list's colour, or `fallback` when it has none. Internal rather than
/// file-private because sidebar rows moved out into their own file.
extension Color {
  init(priorityHex rawValue: String?, fallback: Color) {
    let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "#")) ?? ""
    guard value.count == 6, let hex = UInt64(value, radix: 16) else {
      self = fallback
      return
    }
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255,
      opacity: 1)
  }
}

/// SwiftUI has no API for disabling macOS scroll elasticity entirely.
struct WorkspaceHorizontalOverscrollDisabler: NSViewRepresentable {
  func makeNSView(context: Context) -> Probe { Probe() }
  func updateNSView(_ nsView: Probe, context: Context) {
    nsView.disableOverscroll()
  }

  final class Probe: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      disableOverscroll()
    }

    func disableOverscroll() {
      DispatchQueue.main.async { [weak self] in
        self?.enclosingScrollView?.horizontalScrollElasticity = .none
      }
    }
  }
}
